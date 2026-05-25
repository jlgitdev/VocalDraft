import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import SwiftUI

private let transcribeHotkeyVirtualKeyCode: Int64 = 20 // Top-row 3 on Apple keyboards.
private let editHotkeyVirtualKeyCode: Int64 = 21 // Top-row 4 on Apple keyboards.
private let audioSampleRate: Double = 24_000
private let minimumAudioBytesBeforeCommit = Int(audioSampleRate * 0.12) * MemoryLayout<Int16>.size
private let realtimeTranscriptionModel = "gpt-realtime-whisper"
private let realtimeEditModel = "gpt-realtime-2"
private let transcriptionLanguage = "en"
private let transcriptionDelay = "low"

enum VoiceAction: Equatable {
    case transcribe
    case edit

    var hotkeyVirtualKeyCode: Int64 {
        switch self {
        case .transcribe:
            return transcribeHotkeyVirtualKeyCode
        case .edit:
            return editHotkeyVirtualKeyCode
        }
    }
}

@main
enum VocalDraftMain {
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate
        app.delegate = appDelegate
        app.finishLaunching()
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PillModel()
    private let hotkeyMonitor = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private var overlayController: OverlayWindowController?
    private var transcriber: RealtimeTranscriber?
    private var textEditor: RealtimeTextEditor?
    private var hotkeyRetryTimer: Timer?
    private var isRequestingMicrophonePermission = false
    private var isRecording = false
    private var recordedAudioByteCount = 0
    private var activeVoiceAction: VoiceAction?
    private var activeEditTarget: TextEditTarget?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("VocalDraft keeps a floating overlay visible.")

        overlayController = OverlayWindowController(model: model)
        overlayController?.show()

        recorder.onChunk = { [weak self] data in
            guard let self, !data.isEmpty else { return }

            self.transcriber?.sendAudio(data)
            self.textEditor?.sendAudio(data)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.transcriber != nil || self.textEditor != nil else { return }
                self.recordedAudioByteCount += data.count
            }
        }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.model.level = CGFloat(level)
            }
        }

        hotkeyMonitor.onPress = { [weak self] action in
            self?.beginRecording(action)
        }
        hotkeyMonitor.onRelease = { [weak self] action in
            self?.finishRecording(action)
        }

        startHotkeyMonitor(promptForPermission: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyRetryTimer?.invalidate()
        recorder.stop()
        transcriber?.close()
        textEditor?.close()
        hotkeyMonitor.stop()
    }

    @objc func showAPIKeyPrompt() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "The key is saved to \(APIKeyStore.saveLocationDescription) and used only for realtime transcription."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        field.placeholderString = "sk-..."
        alert.accessoryView = field

        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                showKeyIssue("API key was empty. Paste an OpenAI API key that starts with sk-.")
                return
            }

            do {
                try APIKeyStore.save(key)
                model.status = .idle
            } catch APIKeyStoreError.invalidFormat {
                showKeyIssue("API key should start with sk-. Paste an OpenAI API key from the OpenAI dashboard.")
            } catch {
                showError("Could not save API key to .env.")
            }
        }
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    private func beginRecording(_ action: VoiceAction) {
        guard !isRecording else { return }
        guard transcriber == nil else { return }
        guard textEditor == nil else { return }
        guard ensureMicrophonePermissionBeforeRecording() else { return }

        let apiKey: String
        switch APIKeyStore.load() {
        case .loaded(let loadedAPIKey):
            apiKey = loadedAPIKey
        case .missing:
            NSSound.beep()
            model.status = .keyIssue("Set your OpenAI API key from the pill menu.")
            resetStatusAfterDelay()
            return
        case .invalid(let message):
            showKeyIssue(message)
            return
        }

        recordedAudioByteCount = 0
        activeVoiceAction = action

        switch action {
        case .transcribe:
            let activeTranscriber = RealtimeTranscriber(apiKey: apiKey)
            activeTranscriber.onFinalTranscript = { [weak self] transcript in
                DispatchQueue.main.async {
                    self?.handleFinalTranscript(transcript)
                }
            }
            activeTranscriber.onError = { [weak self] message in
                DispatchQueue.main.async {
                    if Self.isAPIKeyServerError(message) {
                        self?.showKeyIssue("OpenAI rejected the saved API key. Right-click the pill and choose Set API Key...")
                    } else {
                        self?.showError(message)
                    }
                }
            }

            transcriber = activeTranscriber

            do {
                try recorder.start()
            } catch {
                activeTranscriber.close()
                transcriber = nil
                activeVoiceAction = nil
                showError(error.localizedDescription)
                return
            }

            activeTranscriber.connect()

        case .edit:
            let editTarget: TextEditTarget
            do {
                editTarget = try TextEditTargetController.captureFocusedTarget()
            } catch {
                activeVoiceAction = nil
                showError(error.localizedDescription)
                return
            }

            let activeEditor = RealtimeTextEditor(apiKey: apiKey, originalText: editTarget.originalText)
            activeEditor.onEditedText = { [weak self] replacement in
                DispatchQueue.main.async {
                    self?.handleEditedText(replacement)
                }
            }
            activeEditor.onError = { [weak self] message in
                DispatchQueue.main.async {
                    if Self.isAPIKeyServerError(message) {
                        self?.showKeyIssue("OpenAI rejected the saved API key. Right-click the pill and choose Set API Key...")
                    } else {
                        self?.showError(message)
                    }
                }
            }

            activeEditTarget = editTarget
            textEditor = activeEditor

            do {
                try recorder.start()
            } catch {
                activeEditor.close()
                textEditor = nil
                activeEditTarget = nil
                activeVoiceAction = nil
                showError(error.localizedDescription)
                return
            }

            activeEditor.connect()
        }

        isRecording = true
        model.level = 0
        model.status = .recording(action)
    }

    private func finishRecording(_ releasedAction: VoiceAction) {
        guard isRecording else { return }
        guard activeVoiceAction == releasedAction else { return }
        guard let action = activeVoiceAction else { return }

        isRecording = false
        model.level = 0
        model.status = .processing(action)
        let activeTranscriber = transcriber
        let activeEditor = textEditor
        recorder.stopAndDrain { [weak self, activeTranscriber, activeEditor] in
            guard let self else { return }

            let audioByteCount = self.recordedAudioByteCount
            let hasEnoughAudio = audioByteCount >= minimumAudioBytesBeforeCommit
            self.recordedAudioByteCount = 0

            guard hasEnoughAudio else {
                activeTranscriber?.close()
                activeEditor?.close()
                if self.transcriber === activeTranscriber {
                    self.transcriber = nil
                }
                if self.textEditor === activeEditor {
                    self.textEditor = nil
                }
                self.activeEditTarget = nil
                self.activeVoiceAction = nil
                self.model.status = .idle
                return
            }

            switch action {
            case .transcribe:
                guard self.transcriber === activeTranscriber else { return }
                activeTranscriber?.commitAndFinish(audioByteCount: audioByteCount)
            case .edit:
                guard self.textEditor === activeEditor else { return }
                activeEditor?.commitAndEdit(audioByteCount: audioByteCount)
            }
        }
    }

    private func ensureMicrophonePermissionBeforeRecording() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true

        case .notDetermined:
            guard !isRequestingMicrophonePermission else { return false }
            isRequestingMicrophonePermission = true
            model.status = .microphonePermission

            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRequestingMicrophonePermission = false

                    if granted {
                        self.model.status = .idle
                    } else {
                        self.showError("Microphone permission is required. Enable it in System Settings, then hold Command+3 or Command+4 again.")
                    }
                }
            }
            return false

        case .denied, .restricted:
            showError("Microphone permission is required. Enable it in System Settings, then hold Command+3 or Command+4 again.")
            return false

        @unknown default:
            showError("Microphone permission could not be verified.")
            return false
        }
    }

    @discardableResult
    private func startHotkeyMonitor(promptForPermission: Bool) -> Bool {
        do {
            try hotkeyMonitor.start(promptForPermission: promptForPermission)
            hotkeyRetryTimer?.invalidate()
            hotkeyRetryTimer = nil
            model.status = .idle
            return true
        } catch {
            model.status = .error("Grant Accessibility and Input Monitoring permissions in System Settings for VocalDraft.")
            scheduleHotkeyPermissionRetry()
            return false
        }
    }

    private func scheduleHotkeyPermissionRetry() {
        guard hotkeyRetryTimer == nil else { return }

        hotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.startHotkeyMonitor(promptForPermission: false)
        }
    }

    private func handleFinalTranscript(_ transcript: String) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriber = nil
        activeVoiceAction = nil

        guard !cleaned.isEmpty else {
            model.status = .idle
            return
        }

        TextReplacementTyper.paste(cleaned)
        model.status = .idle
    }

    private func handleEditedText(_ replacement: String) {
        let target = activeEditTarget
        textEditor = nil
        activeEditTarget = nil
        activeVoiceAction = nil

        guard let target else {
            model.status = .idle
            return
        }

        do {
            try TextEditTargetController.applyReplacement(replacement, to: target)
            model.status = .idle
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showKeyIssue(_ message: String) {
        NSLog("VocalDraft API key issue: %@", message)

        if isRecording {
            isRecording = false
            recorder.stop()
        }
        recordedAudioByteCount = 0
        transcriber?.close()
        transcriber = nil
        textEditor?.close()
        textEditor = nil
        activeEditTarget = nil
        activeVoiceAction = nil

        NSSound.beep()
        model.status = .keyIssue(message)
        resetStatusAfterDelay()
    }

    private func showError(_ message: String) {
        NSLog("VocalDraft error: %@", message)

        if isRecording {
            isRecording = false
            recorder.stop()
        }
        recordedAudioByteCount = 0
        transcriber?.close()
        transcriber = nil
        textEditor?.close()
        textEditor = nil
        activeEditTarget = nil
        activeVoiceAction = nil

        NSSound.beep()
        model.status = .error(message)
        resetStatusAfterDelay()
    }

    private func resetStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.isRecording, self.hotkeyRetryTimer == nil else { return }
            self.model.status = .idle
        }
    }

    private static func isAPIKeyServerError(_ message: String) -> Bool {
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.contains("api key") ||
            lowercasedMessage.contains("authentication") ||
            lowercasedMessage.contains("unauthorized") ||
            lowercasedMessage.contains("invalid_request_error")
    }
}

enum PillStatus: Equatable {
    case idle
    case recording(VoiceAction)
    case processing(VoiceAction)
    case microphonePermission
    case keyIssue(String)
    case error(String)

    var isRecording: Bool {
        if case .recording = self {
            return true
        }
        return false
    }

    var iconName: String {
        switch self {
        case .idle:
            return "mic"
        case .recording(.transcribe):
            return "waveform"
        case .recording(.edit):
            return "pencil"
        case .processing(_):
            return "hourglass"
        case .microphonePermission:
            return "mic"
        case .keyIssue:
            return "key"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    var label: String {
        switch self {
        case .idle:
            return "⌘3/4"
        case .recording(_):
            return "Live"
        case .processing(.transcribe):
            return "..."
        case .processing(.edit):
            return "Edit"
        case .microphonePermission:
            return "Mic"
        case .keyIssue:
            return "Key"
        case .error(let message):
            if message.localizedCaseInsensitiveContains("permission") ||
                message.localizedCaseInsensitiveContains("accessibility") ||
                message.localizedCaseInsensitiveContains("input monitoring") {
                return "Perm"
            }
            return "Error"
        }
    }

    var helpText: String {
        switch self {
        case .idle:
            return "Hold Command+3 to transcribe or Command+4 to edit selected text."
        case .recording(.transcribe):
            return "Recording transcription."
        case .recording(.edit):
            return "Recording edit instruction."
        case .processing(.transcribe):
            return "Transcribing."
        case .processing(.edit):
            return "Editing."
        case .microphonePermission:
            return "Allow microphone access, then hold Command+3 or Command+4 again."
        case .keyIssue(let message):
            return message
        case .error(let message):
            return message
        }
    }
}

final class PillModel: ObservableObject {
    @Published var status: PillStatus = .idle
    @Published var level: CGFloat = 0
}

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.status.iconName)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)

            if model.status.isRecording {
                WaveformView(level: model.level)
                    .frame(width: 104, height: 28)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                Text(model.status.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: model.status.isRecording ? 172 : 104, height: 52)
        .background(Color.clear)
        .background(pillBackground)
        .help(model.status.helpText)
        .animation(.spring(response: 0.22, dampingFraction: 0.84), value: model.status)
    }

    private var pillBackground: some View {
        Capsule(style: .continuous)
            .fill(.black.opacity(0.78))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(.white.opacity(model.status.isRecording ? 0.24 : 0.14), lineWidth: 1)
            )
    }

    private var iconColor: Color {
        switch model.status {
        case .recording(_):
            return .green
        case .processing(_):
            return .yellow
        case .microphonePermission, .keyIssue, .error:
            return .orange
        case .idle:
            return .white.opacity(0.88)
        }
    }
}

struct WaveformView: View {
    let level: CGFloat
    private let barCount = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = sin(t * 7.0 + Double(index) * 0.72)
                    let normalizedPhase = CGFloat((phase + 1.0) / 2.0)
                    let height = 6 + (level * 25) + (normalizedPhase * max(level, 0.12) * 14)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.green.opacity(0.72 + normalizedPhase * 0.22))
                        .frame(width: 3.5, height: min(30, max(5, height)))
                }
            }
        }
    }
}

final class OverlayWindowController {
    private let window: DraggableWindow

    init(model: PillModel) {
        let size = NSSize(width: 176, height: 56)
        let origin = WindowPositionStore.load(size: size)
        window = DraggableWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let menu = Self.makeMenu()
        let hostingView = DraggableHostingView(rootView: PillView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.menu = menu
        window.menu = menu
        window.contentView = hostingView
    }

    func show() {
        window.orderFrontRegardless()
        window.setIsVisible(true)
    }

    private static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let keyItem = NSMenuItem(title: "Set API Key...", action: #selector(AppDelegate.showAPIKeyPrompt), keyEquivalent: "")
        keyItem.target = NSApp.delegate
        menu.addItem(keyItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(AppDelegate.quitApp), keyEquivalent: "q")
        quitItem.target = NSApp.delegate
        menu.addItem(quitItem)

        return menu
    }
}

final class DraggableWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func rightMouseDown(with event: NSEvent) {
        guard let contentView, let menu = menu ?? contentView.menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    private var dragOffset: NSPoint = .zero

    override var isOpaque: Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearBackingLayer()
    }

    override func layout() {
        super.layout()
        clearBackingLayer()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }

        dragOffset = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }

        let current = NSEvent.mouseLocation
        let newOrigin = NSPoint(x: current.x - dragOffset.x, y: current.y - dragOffset.y)
        window.setFrameOrigin(newOrigin)
        WindowPositionStore.save(newOrigin)
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func showContextMenu(with event: NSEvent) {
        guard let menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func clearBackingLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

enum WindowPositionStore {
    private static let xKey = "overlay.origin.x"
    private static let yKey = "overlay.origin.y"

    static func load(size: NSSize) -> NSPoint {
        let defaults = UserDefaults.standard
        let savedX = defaults.object(forKey: xKey) as? Double
        let savedY = defaults.object(forKey: yKey) as? Double
        let visible = visibleFrame(for: savedX.flatMap { x in savedY.map { NSPoint(x: x, y: $0) } })

        if let savedX, let savedY {
            let origin = clamped(NSPoint(x: savedX, y: savedY), size: size, visibleFrame: visible)
            save(origin)
            return origin
        }

        let origin = NSPoint(
            x: visible.midX - (size.width / 2),
            y: visible.maxY - size.height - 96
        )
        let clampedOrigin = clamped(origin, size: size, visibleFrame: visible)
        save(clampedOrigin)
        return clampedOrigin
    }

    static func save(_ origin: NSPoint) {
        let defaults = UserDefaults.standard
        defaults.set(origin.x, forKey: xKey)
        defaults.set(origin.y, forKey: yKey)
    }

    private static func visibleFrame(for origin: NSPoint?) -> NSRect {
        let fallback = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard let origin else { return fallback }

        return NSScreen.screens
            .map(\.visibleFrame)
            .first { $0.insetBy(dx: -200, dy: -200).contains(origin) } ?? fallback
    }

    private static func clamped(_ origin: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
        let sideMargin: CGFloat = 24
        let bottomMargin: CGFloat = 24
        let topMargin: CGFloat = 96
        let minX = visibleFrame.minX + sideMargin
        let maxX = max(minX, visibleFrame.maxX - size.width - sideMargin)
        let minY = visibleFrame.minY + bottomMargin
        let maxY = max(minY, visibleFrame.maxY - size.height - topMargin)

        return NSPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }
}

enum HotkeyEventOutcome: Equatable {
    case press(VoiceAction)
    case release(VoiceAction)
    case none
}

struct HotkeyStateMachine {
    private(set) var activeAction: VoiceAction?

    mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> HotkeyEventOutcome {
        if type == .keyDown, let action = Self.action(forKeyCode: keyCode, flags: flags) {
            guard activeAction == nil else { return .none }
            activeAction = action
            return .press(action)
        }

        if type == .keyUp, let action = activeAction, keyCode == action.hotkeyVirtualKeyCode {
            activeAction = nil
            return .release(action)
        }

        if type == .flagsChanged, let action = activeAction, !Self.isHotkeyModifierMatch(flags) {
            activeAction = nil
            return .release(action)
        }

        return .none
    }

    static func action(forKeyCode keyCode: Int64, flags: CGEventFlags) -> VoiceAction? {
        guard isHotkeyModifierMatch(flags) else { return nil }

        switch keyCode {
        case transcribeHotkeyVirtualKeyCode:
            return .transcribe
        case editHotkeyVirtualKeyCode:
            return .edit
        default:
            return nil
        }
    }

    private static func isHotkeyModifierMatch(_ flags: CGEventFlags) -> Bool {
        let disallowedModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate]
        return flags.contains(.maskCommand) && flags.intersection(disallowedModifiers).isEmpty
    }
}

final class HotkeyMonitor {
    var onPress: ((VoiceAction) -> Void)?
    var onRelease: ((VoiceAction) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var stateMachine = HotkeyStateMachine()

    func start(promptForPermission: Bool) throws {
        guard eventTap == nil else { return }

        if promptForPermission {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        } else if !AXIsProcessTrusted() {
            throw HotkeyError.permissionRequired
        }

        let eventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.permissionRequired
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        stateMachine = HotkeyStateMachine()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch stateMachine.handle(type: type, keyCode: keyCode, flags: event.flags) {
        case .press(let action):
            DispatchQueue.main.async { [weak self] in
                self?.onPress?(action)
            }
            return nil

        case .release(let action):
            DispatchQueue.main.async { [weak self] in
                self?.onRelease?(action)
            }
            return nil

        case .none:
            return Unmanaged.passUnretained(event)
        }
    }
}

enum HotkeyError: LocalizedError {
    case permissionRequired

    var errorDescription: String? {
        "Accessibility permission is required for the Command+3 and Command+4 hold hotkeys."
    }
}

final class AudioRecorder {
    var onChunk: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let audioQueue = DispatchQueue(label: "VocalDraft.audio")
    private var isRunning = false

    func start() throws {
        guard !isRunning else { return }
        try ensureMicrophonePermission()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        guard let transcriptionFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audioSampleRate,
            channels: 1,
            interleaved: false
        ),
            let converter = AVAudioConverter(from: inputFormat, to: transcriptionFormat) else {
            throw AudioRecorderError.audioConversionUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 1_200, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let level = Self.level(from: buffer)
            let copiedBuffer = Self.copyAudioBuffer(buffer)

            self.audioQueue.async { [weak self] in
                guard let copiedBuffer else { return }
                let pcm = Self.pcm16Data(from: copiedBuffer, converter: converter, outputFormat: transcriptionFormat)
                self?.onChunk?(pcm)
            }
            self.onLevel?(level)
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            engine.reset()
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        isRunning = false
        onLevel?(0)
    }

    func stopAndDrain(_ completion: @escaping () -> Void) {
        stop()
        audioQueue.async {
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func ensureMicrophonePermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            throw AudioRecorderError.microphonePermission
        default:
            throw AudioRecorderError.microphonePermission
        }
    }

    private static func copyAudioBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }

        copiedBuffer.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let copiedBuffers = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)

        for index in 0..<min(sourceBuffers.count, copiedBuffers.count) {
            guard let source = sourceBuffers[index].mData,
                  let destination = copiedBuffers[index].mData else {
                continue
            }

            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            destination.copyMemory(from: source, byteCount: byteCount)
            copiedBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copiedBuffer
    }

    private static func pcm16Data(
        from buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 16)
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(outputFrameCapacity, 1)
        ) else {
            return Data()
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil else {
            NSLog("VocalDraft audio conversion failed: %@", conversionError?.localizedDescription ?? "unknown error")
            return Data()
        }

        return pcm16Data(fromConvertedBuffer: convertedBuffer)
    }

    private static func pcm16Data(fromConvertedBuffer buffer: AVAudioPCMBuffer) -> Data {
        guard let channel = buffer.floatChannelData?[0] else { return Data() }

        let frames = Int(buffer.frameLength)
        var data = Data()
        data.reserveCapacity(frames * MemoryLayout<Int16>.size)

        for index in 0..<frames {
            let clamped = max(-1, min(1, channel[index]))
            let sample = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: sample) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        return data
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }

        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return 0 }

        var sum: Float = 0
        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for index in 0..<frames {
                sum += channel[index] * channel[index]
            }
        }

        let rms = sqrt(sum / Float(frames * channelCount))
        return min(1, max(0, rms * 8))
    }
}

enum AudioRecorderError: LocalizedError {
    case microphonePermission
    case noInputDevice
    case audioConversionUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermission:
            return "Microphone permission is required."
        case .noInputDevice:
            return "No microphone input device was found."
        case .audioConversionUnavailable:
            return "Microphone audio could not be converted for transcription."
        }
    }
}

enum TextEditTargetKind: Equatable {
    case selection
    case wholeField
}

struct TextRange: Equatable {
    let location: Int
    let length: Int

    init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    init(_ range: CFRange) {
        self.location = range.location
        self.length = range.length
    }

    var cfRange: CFRange {
        CFRange(location: location, length: length)
    }
}

struct TextTargetCandidate: Equatable {
    let selectedText: String?
    let selectedRange: TextRange?
    let value: String?
    let isValueSettable: Bool
    let role: String?
}

struct ResolvedTextEditTarget: Equatable {
    let originalText: String
    let kind: TextEditTargetKind
    let selectedRange: TextRange?
}

enum TextTargetResolver {
    static func resolve(_ candidate: TextTargetCandidate) -> ResolvedTextEditTarget? {
        if let selectedText = candidate.selectedText,
           !selectedText.isEmpty,
           let selectedRange = candidate.selectedRange,
           selectedRange.length > 0 {
            return ResolvedTextEditTarget(
                originalText: selectedText,
                kind: .selection,
                selectedRange: selectedRange
            )
        }

        guard let value = candidate.value else { return nil }
        guard !value.isEmpty || isLikelyEditable(role: candidate.role, isValueSettable: candidate.isValueSettable) else {
            return nil
        }

        return ResolvedTextEditTarget(originalText: value, kind: .wholeField, selectedRange: nil)
    }

    static func isLikelyEditable(role: String?, isValueSettable: Bool) -> Bool {
        if isValueSettable {
            return true
        }

        guard let role else { return false }
        let editableRoles: Set<String> = [
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String,
            "AXSearchField"
        ]
        return editableRoles.contains(role)
    }
}

enum TextReplacementPlan: Equatable {
    case restoreSelectionAndPaste(range: TextRange, replacement: String)
    case directSetValue(String)
    case selectAllAndPaste(String)
    case abortFocusChanged
    case abortEmptyReplacement
}

enum TextTargetApplyPlanner {
    static func plan(
        target: ResolvedTextEditTarget,
        replacement: String,
        isFocusedElementSame: Bool,
        canSetWholeValue: Bool
    ) -> TextReplacementPlan {
        guard isFocusedElementSame else { return .abortFocusChanged }
        guard !replacement.isEmpty || target.originalText.isEmpty else { return .abortEmptyReplacement }

        switch target.kind {
        case .selection:
            guard let selectedRange = target.selectedRange else { return .abortFocusChanged }
            return .restoreSelectionAndPaste(range: selectedRange, replacement: replacement)
        case .wholeField:
            return canSetWholeValue ? .directSetValue(replacement) : .selectAllAndPaste(replacement)
        }
    }
}

struct TextEditTarget {
    let element: AXUIElement
    let resolved: ResolvedTextEditTarget

    var originalText: String {
        resolved.originalText
    }
}

enum TextEditTargetError: LocalizedError {
    case noFocusedTextTarget
    case targetChanged
    case emptyReplacement
    case couldNotApplyReplacement

    var errorDescription: String? {
        switch self {
        case .noFocusedTextTarget:
            return "Focus an editable text field or select text before using Command+4."
        case .targetChanged:
            return "Edit target changed. Try again."
        case .emptyReplacement:
            return "Edit returned no replacement text."
        case .couldNotApplyReplacement:
            return "Could not replace the focused text."
        }
    }
}

enum TextEditTargetController {
    static func captureFocusedTarget() throws -> TextEditTarget {
        guard let element = focusedElement() else {
            throw TextEditTargetError.noFocusedTextTarget
        }

        let candidate = TextTargetCandidate(
            selectedText: stringAttribute(kAXSelectedTextAttribute as CFString, from: element),
            selectedRange: textRangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: element),
            value: stringAttribute(kAXValueAttribute as CFString, from: element),
            isValueSettable: isAttributeSettable(kAXValueAttribute as CFString, on: element),
            role: stringAttribute(kAXRoleAttribute as CFString, from: element)
        )

        guard let resolved = TextTargetResolver.resolve(candidate) else {
            throw TextEditTargetError.noFocusedTextTarget
        }

        return TextEditTarget(element: element, resolved: resolved)
    }

    static func applyReplacement(_ replacement: String, to target: TextEditTarget) throws {
        let isFocusedElementSame = focusedElement().map { CFEqual($0, target.element) } ?? false
        let canSetWholeValue = isAttributeSettable(kAXValueAttribute as CFString, on: target.element)

        switch TextTargetApplyPlanner.plan(
            target: target.resolved,
            replacement: replacement,
            isFocusedElementSame: isFocusedElementSame,
            canSetWholeValue: canSetWholeValue
        ) {
        case .abortFocusChanged:
            throw TextEditTargetError.targetChanged
        case .abortEmptyReplacement:
            throw TextEditTargetError.emptyReplacement
        case .restoreSelectionAndPaste(let range, let replacement):
            guard setTextRange(range, attribute: kAXSelectedTextRangeAttribute as CFString, on: target.element) else {
                throw TextEditTargetError.couldNotApplyReplacement
            }
            TextReplacementTyper.paste(replacement)
        case .directSetValue(let replacement):
            let error = AXUIElementSetAttributeValue(
                target.element,
                kAXValueAttribute as CFString,
                replacement as CFTypeRef
            )
            if error == .success {
                return
            }
            focus(target.element)
            TextReplacementTyper.selectAll()
            TextReplacementTyper.paste(replacement)
        case .selectAllAndPaste(let replacement):
            focus(target.element)
            TextReplacementTyper.selectAll()
            TextReplacementTyper.paste(replacement)
        }
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return (focusedValue as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private static func textRangeAttribute(_ attribute: CFString, from element: AXUIElement) -> TextRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return TextRange(range)
    }

    private static func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &isSettable) == .success && isSettable.boolValue
    }

    private static func setTextRange(_ range: TextRange, attribute: CFString, on element: AXUIElement) -> Bool {
        var cfRange = range.cfRange
        guard let value = AXValueCreate(.cfRange, &cfRange) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, attribute, value) == .success
    }

    private static func focus(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
}

enum RealtimeTranscriptionProtocol {
    static let timeoutErrorMessage = "Transcription timed out. Try again."

    static func webSocketURL() -> URL? {
        URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")
    }

    static func sessionUpdateEvent() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(audioSampleRate)
                        ],
                        "transcription": [
                            "model": realtimeTranscriptionModel,
                            "language": transcriptionLanguage,
                            "delay": transcriptionDelay
                        ],
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
    }

    static func commitEvent() -> [String: Any] {
        ["type": "input_audio_buffer.commit"]
    }

    static func completionTimeout(forAudioByteCount audioByteCount: Int) -> TimeInterval {
        let bytesPerSecond = audioSampleRate * Double(MemoryLayout<Int16>.size)
        let duration = max(0, Double(audioByteCount) / bytesPerSecond)
        return min(120, max(20, duration * 2 + 10))
    }
}

enum RealtimeEditProtocol {
    static let timeoutErrorMessage = "Edit timed out. Try again."
    static let emptyReplacementErrorMessage = "Edit returned no replacement text."

    static let instructions = """
    You are a text replacement engine. Return only the final replacement text.
    Do not explain your changes. Do not wrap the output in quotes or code fences.
    Apply the user's spoken instruction to the supplied target text.
    Preserve the target text's meaning, voice, formatting, and style unless the spoken instruction asks for a change.
    If the target text is empty, generate text from the spoken instruction.
    """

    static func webSocketURL() -> URL? {
        URL(string: "wss://api.openai.com/v1/realtime?model=\(realtimeEditModel)")
    }

    static func sessionUpdateEvent() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": instructions,
                "output_modalities": ["text"],
                "reasoning": [
                    "effort": "low"
                ],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(audioSampleRate)
                        ],
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
    }

    static func contextItemEvent(originalText: String) -> [String: Any] {
        let prompt = """
        The following is the target text to edit. The next audio message contains the user's edit instruction.

        Return only the complete replacement text after applying that spoken instruction.

        <target_text>
        \(originalText)
        </target_text>
        """

        return [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": prompt
                    ]
                ]
            ]
        ]
    }

    static func commitEvent() -> [String: Any] {
        ["type": "input_audio_buffer.commit"]
    }

    static func responseCreateEvent() -> [String: Any] {
        [
            "type": "response.create",
            "response": [
                "output_modalities": ["text"]
            ]
        ]
    }

    static func completionTimeout(forAudioByteCount audioByteCount: Int) -> TimeInterval {
        let bytesPerSecond = audioSampleRate * Double(MemoryLayout<Int16>.size)
        let duration = max(0, Double(audioByteCount) / bytesPerSecond)
        return min(120, max(20, duration * 2 + 10))
    }

    static func sanitizedReplacement(from text: String, originalText: String) -> String? {
        let stripped = stripSurroundingCodeFence(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty || originalText.isEmpty else {
            return nil
        }
        return stripped
    }

    private static func stripSurroundingCodeFence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else {
            return trimmed
        }

        var lines = trimmed.components(separatedBy: .newlines)
        guard let firstLine = lines.first,
              firstLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") else {
            return trimmed
        }

        lines.removeFirst()
        if let lastLine = lines.last,
           lastLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }
}

enum RealtimeEditParseResult: Equatable {
    case none
    case completed(String)
    case error(String)
}

struct RealtimeEditEventParser {
    private let originalText: String
    private var accumulatedText = ""
    private var completedText: String?

    init(originalText: String) {
        self.originalText = originalText
    }

    mutating func handle(event: [String: Any]) -> RealtimeEditParseResult {
        guard let type = event["type"] as? String else {
            return .none
        }

        switch type {
        case "response.output_text.delta":
            accumulatedText += event["delta"] as? String ?? ""
            return .none

        case "response.output_text.done":
            completedText = event["text"] as? String ?? completedText
            return .none

        case "response.done":
            let rawText = completedText ?? (!accumulatedText.isEmpty ? accumulatedText : Self.extractTextFromResponseDone(event))
            guard let rawText,
                  let replacement = RealtimeEditProtocol.sanitizedReplacement(from: rawText, originalText: originalText) else {
                return .error(RealtimeEditProtocol.emptyReplacementErrorMessage)
            }
            return .completed(replacement)

        case "error":
            if let error = event["error"] as? [String: Any],
               let message = error["message"] as? String {
                if (error["code"] as? String) == "unknown_parameter" {
                    return .error("Realtime schema error: \(message)")
                }
                return .error(message)
            }
            return .error("Realtime edit returned an error.")

        default:
            return .none
        }
    }

    private static func extractTextFromResponseDone(_ event: [String: Any]) -> String? {
        guard let response = event["response"] as? [String: Any],
              let output = response["output"] as? [[String: Any]] else {
            return nil
        }

        var textParts: [String] = []
        for outputItem in output {
            if let text = outputItem["text"] as? String {
                textParts.append(text)
            }

            guard let content = outputItem["content"] as? [[String: Any]] else { continue }
            for contentPart in content {
                if let text = contentPart["text"] as? String {
                    textParts.append(text)
                } else if let transcript = contentPart["transcript"] as? String {
                    textParts.append(transcript)
                }
            }
        }

        return textParts.isEmpty ? nil : textParts.joined()
    }
}

final class RealtimeTranscriber {
    var onFinalTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let apiKey: String
    private let queue = DispatchQueue(label: "VocalDraft.realtime")
    private var socket: URLSessionWebSocketTask?
    private var pendingClientEvents: [[String: Any]] = []
    private var partialByItemID: [String: String] = [:]
    private var hasFinished = false
    private var isAwaitingFinalTranscript = false
    private var finalTranscriptTimeoutWorkItem: DispatchWorkItem?
    private var shouldIgnoreSocketErrors = false

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func connect() {
        queue.async { [weak self] in
            self?.openSocket()
        }
    }

    func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }

        let base64 = data.base64EncodedString()
        queue.async { [weak self] in
            guard let self, !self.hasFinished else { return }
            self.sendJSON([
                "type": "input_audio_buffer.append",
                "audio": base64
            ])
        }
    }

    func commitAndFinish(audioByteCount: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.hasFinished else { return }
            self.isAwaitingFinalTranscript = true
            self.sendJSON(RealtimeTranscriptionProtocol.commitEvent())
            self.scheduleFinalTranscriptTimeout(audioByteCount: audioByteCount)
        }
    }

    func close() {
        queue.async {
            self.shouldIgnoreSocketErrors = true
            self.cancelFinalTranscriptTimeout()
            self.pendingClientEvents.removeAll()
            self.socket?.cancel(with: .goingAway, reason: nil)
            self.socket = nil
        }
    }

    private func openSocket() {
        guard socket == nil else { return }

        guard let url = RealtimeTranscriptionProtocol.webSocketURL() else {
            reportError("Realtime URL was invalid.")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(SafetyIdentifier.current, forHTTPHeaderField: "OpenAI-Safety-Identifier")

        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        receiveLoop()
        task.resume()
        sendSessionUpdate()
        flushPendingClientEvents()
    }

    private func sendSessionUpdate() {
        sendJSON(RealtimeTranscriptionProtocol.sessionUpdateEvent())
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let socket else {
            pendingClientEvents.append(object)
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let text = String(data: data, encoding: .utf8) else { return }
            socket.send(.string(text)) { [weak self] error in
                if let error {
                    self?.queue.async {
                        guard let self, !self.shouldIgnoreSocketErrors else { return }
                        self.reportError("Realtime send failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            reportError("Could not encode realtime event.")
        }
    }

    private func flushPendingClientEvents() {
        let events = pendingClientEvents
        pendingClientEvents.removeAll()

        for event in events {
            sendJSON(event)
        }
    }

    private func receiveLoop() {
        guard let socket else { return }

        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.handleReceive(result)
            }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            handle(message)
            receiveLoop()
        case .failure(let error):
            if !shouldIgnoreSocketErrors {
                reportError("Realtime connection failed: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }

        guard let text,
              let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            let itemID = event["item_id"] as? String ?? "default"
            let delta = event["delta"] as? String ?? ""
            partialByItemID[itemID, default: ""] += delta

        case "conversation.item.input_audio_transcription.completed":
            let transcript = event["transcript"] as? String ?? ""
            finish(transcript: transcript)

        case "error":
            if let error = event["error"] as? [String: Any],
               let message = error["message"] as? String {
                reportError(message)
            } else {
                reportError("Realtime transcription returned an error.")
            }

        default:
            break
        }
    }

    private func finish(transcript: String) {
        guard !hasFinished else { return }
        cancelFinalTranscriptTimeout()
        hasFinished = true
        shouldIgnoreSocketErrors = true
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        onFinalTranscript?(transcript)
    }

    private func reportError(_ message: String) {
        guard !hasFinished else { return }
        cancelFinalTranscriptTimeout()
        hasFinished = true
        shouldIgnoreSocketErrors = true
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onError?(message)
    }

    private func scheduleFinalTranscriptTimeout(audioByteCount: Int) {
        cancelFinalTranscriptTimeout()
        isAwaitingFinalTranscript = true

        let timeout = RealtimeTranscriptionProtocol.completionTimeout(forAudioByteCount: audioByteCount)
        let workItem = DispatchWorkItem { [weak self] in
            self?.queue.async {
                guard let self, !self.hasFinished, self.isAwaitingFinalTranscript else { return }
                self.reportError(RealtimeTranscriptionProtocol.timeoutErrorMessage)
            }
        }

        finalTranscriptTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func cancelFinalTranscriptTimeout() {
        finalTranscriptTimeoutWorkItem?.cancel()
        finalTranscriptTimeoutWorkItem = nil
        isAwaitingFinalTranscript = false
    }
}

final class RealtimeTextEditor {
    var onEditedText: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let apiKey: String
    private let originalText: String
    private let queue = DispatchQueue(label: "VocalDraft.realtime-edit")
    private var socket: URLSessionWebSocketTask?
    private var pendingClientEvents: [[String: Any]] = []
    private var parser: RealtimeEditEventParser
    private var hasFinished = false
    private var isAwaitingEditedText = false
    private var editedTextTimeoutWorkItem: DispatchWorkItem?
    private var shouldIgnoreSocketErrors = false

    init(apiKey: String, originalText: String) {
        self.apiKey = apiKey
        self.originalText = originalText
        self.parser = RealtimeEditEventParser(originalText: originalText)
    }

    func connect() {
        queue.async { [weak self] in
            self?.openSocket()
        }
    }

    func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }

        let base64 = data.base64EncodedString()
        queue.async { [weak self] in
            guard let self, !self.hasFinished else { return }
            self.sendJSON([
                "type": "input_audio_buffer.append",
                "audio": base64
            ])
        }
    }

    func commitAndEdit(audioByteCount: Int) {
        queue.async { [weak self] in
            guard let self, !self.hasFinished else { return }
            self.isAwaitingEditedText = true
            self.sendJSON(RealtimeEditProtocol.commitEvent())
            self.sendJSON(RealtimeEditProtocol.responseCreateEvent())
            self.scheduleEditedTextTimeout(audioByteCount: audioByteCount)
        }
    }

    func close() {
        queue.async {
            self.shouldIgnoreSocketErrors = true
            self.cancelEditedTextTimeout()
            self.pendingClientEvents.removeAll()
            self.socket?.cancel(with: .goingAway, reason: nil)
            self.socket = nil
        }
    }

    private func openSocket() {
        guard socket == nil else { return }

        guard let url = RealtimeEditProtocol.webSocketURL() else {
            reportError("Realtime edit URL was invalid.")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(SafetyIdentifier.current, forHTTPHeaderField: "OpenAI-Safety-Identifier")

        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        receiveLoop()
        task.resume()
        sendSessionSetup()
        flushPendingClientEvents()
    }

    private func sendSessionSetup() {
        sendJSON(RealtimeEditProtocol.sessionUpdateEvent())
        sendJSON(RealtimeEditProtocol.contextItemEvent(originalText: originalText))
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let socket else {
            pendingClientEvents.append(object)
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let text = String(data: data, encoding: .utf8) else { return }
            socket.send(.string(text)) { [weak self] error in
                if let error {
                    self?.queue.async {
                        guard let self, !self.shouldIgnoreSocketErrors else { return }
                        self.reportError("Realtime edit send failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            reportError("Could not encode realtime edit event.")
        }
    }

    private func flushPendingClientEvents() {
        let events = pendingClientEvents
        pendingClientEvents.removeAll()

        for event in events {
            sendJSON(event)
        }
    }

    private func receiveLoop() {
        guard let socket else { return }

        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.handleReceive(result)
            }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            handle(message)
            receiveLoop()
        case .failure(let error):
            if !shouldIgnoreSocketErrors {
                reportError("Realtime edit connection failed: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }

        guard let text,
              let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        switch parser.handle(event: event) {
        case .none:
            break
        case .completed(let replacement):
            finish(replacement: replacement)
        case .error(let message):
            reportError(message)
        }
    }

    private func finish(replacement: String) {
        guard !hasFinished else { return }
        cancelEditedTextTimeout()
        hasFinished = true
        shouldIgnoreSocketErrors = true
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        onEditedText?(replacement)
    }

    private func reportError(_ message: String) {
        guard !hasFinished else { return }
        cancelEditedTextTimeout()
        hasFinished = true
        shouldIgnoreSocketErrors = true
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onError?(message)
    }

    private func scheduleEditedTextTimeout(audioByteCount: Int) {
        cancelEditedTextTimeout()
        isAwaitingEditedText = true

        let timeout = RealtimeEditProtocol.completionTimeout(forAudioByteCount: audioByteCount)
        let workItem = DispatchWorkItem { [weak self] in
            self?.queue.async {
                guard let self, !self.hasFinished, self.isAwaitingEditedText else { return }
                self.reportError(RealtimeEditProtocol.timeoutErrorMessage)
            }
        }

        editedTextTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func cancelEditedTextTimeout() {
        editedTextTimeoutWorkItem?.cancel()
        editedTextTimeoutWorkItem = nil
        isAwaitingEditedText = false
    }
}

enum SafetyIdentifier {
    private static let key = "openai.safetyIdentifier"

    static var current: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key) {
            return existing
        }

        let value = "local-\(UUID().uuidString.lowercased())"
        defaults.set(value, forKey: key)
        return value
    }
}

enum APIKeyStore {
    private static let variableName = "OPENAI_API_KEY"
    private static let fileName = ".env"

    enum LoadResult {
        case loaded(String)
        case missing
        case invalid(String)
    }

    static var saveLocationDescription: String {
        preferredEnvFileURL().path
    }

    static func load() -> LoadResult {
        if let envValue = cleanValue(ProcessInfo.processInfo.environment[variableName]) {
            guard isPlausibleAPIKey(envValue) else {
                return .invalid("OPENAI_API_KEY in the process environment is not an OpenAI API key. It should start with sk-.")
            }
            return .loaded(envValue)
        }

        for url in candidateEnvFileURLs() where FileManager.default.isReadableFile(atPath: url.path) {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let key = key(fromEnvContents: contents) {
                guard isPlausibleAPIKey(key) else {
                    return .invalid("The saved OPENAI_API_KEY in \(url.path) is not an OpenAI API key. It should start with sk-.")
                }
                return .loaded(key)
            }
        }

        return .missing
    }

    static func save(_ key: String) throws {
        guard isPlausibleAPIKey(key) else {
            throw APIKeyStoreError.invalidFormat
        }

        let url = preferredEnvFileURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existingContents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updatedContents = upserting(key: key, inEnvContents: existingContents)
        try updatedContents.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func preferredEnvFileURL() -> URL {
        if let existingURL = candidateEnvFileURLs().first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return existingURL
        }

        if let projectRootURL {
            return projectRootURL.appendingPathComponent(fileName)
        }

        return applicationSupportEnvFileURL
    }

    private static func candidateEnvFileURLs() -> [URL] {
        uniqueURLs([
            projectRootURL?.appendingPathComponent(fileName),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(fileName),
            Bundle.main.resourceURL?.appendingPathComponent(fileName),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(fileName),
            applicationSupportEnvFileURL
        ])
    }

    private static var projectRootURL: URL? {
        let startURLs = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle.main.bundleURL,
            Bundle.main.resourceURL
        ].compactMap(\.self)

        for startURL in startURLs {
            if let rootURL = ancestorContainingPackageManifest(startingAt: startURL) {
                return rootURL
            }
        }

        return nil
    }

    private static var applicationSupportEnvFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VocalDraft", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static func ancestorContainingPackageManifest(startingAt startURL: URL) -> URL? {
        var url = startURL.hasDirectoryPath ? startURL : startURL.deletingLastPathComponent()

        for _ in 0..<12 {
            let manifestURL = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return url
            }

            let parentURL = url.deletingLastPathComponent()
            guard parentURL.path != url.path else { break }
            url = parentURL
        }

        return nil
    }

    private static func uniqueURLs(_ urls: [URL?]) -> [URL] {
        var seenPaths = Set<String>()
        var uniqueURLs: [URL] = []

        for url in urls.compactMap(\.self) {
            let standardizedURL = url.standardizedFileURL
            guard seenPaths.insert(standardizedURL.path).inserted else { continue }
            uniqueURLs.append(standardizedURL)
        }

        return uniqueURLs
    }

    private static func key(fromEnvContents contents: String) -> String? {
        for line in contents.components(separatedBy: .newlines) {
            var trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else { continue }

            if trimmedLine.hasPrefix("export ") {
                trimmedLine = String(trimmedLine.dropFirst("export ".count))
                    .trimmingCharacters(in: .whitespaces)
            }

            guard let equalsIndex = trimmedLine.firstIndex(of: "=") else { continue }
            let name = String(trimmedLine[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            guard name == variableName else { continue }

            let rawValue = String(trimmedLine[trimmedLine.index(after: equalsIndex)...])
            if let value = cleanValue(parseEnvValue(rawValue)) {
                return value
            }
        }

        return nil
    }

    private static func parseEnvValue(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespaces)

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            let innerValue = String(value.dropFirst().dropLast())
            return unescapeDoubleQuotedEnvValue(innerValue)
        }

        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }

        return stripInlineComment(from: value)
    }

    private static func unescapeDoubleQuotedEnvValue(_ value: String) -> String {
        var result = ""
        var isEscaping = false

        for character in value {
            if isEscaping {
                switch character {
                case "n":
                    result.append("\n")
                case "r":
                    result.append("\r")
                case "t":
                    result.append("\t")
                case "\"":
                    result.append("\"")
                case "\\":
                    result.append("\\")
                default:
                    result.append(character)
                }
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }

        if isEscaping {
            result.append("\\")
        }

        return result
    }

    private static func stripInlineComment(from value: String) -> String {
        for index in value.indices where value[index] == "#" {
            guard index == value.startIndex || value[value.index(before: index)].isWhitespace else { continue }
            return String(value[..<index]).trimmingCharacters(in: .whitespaces)
        }

        return value
    }

    private static func cleanValue(_ value: String?) -> String? {
        guard let cleanedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleanedValue.isEmpty else {
            return nil
        }

        return cleanedValue
    }

    private static func isPlausibleAPIKey(_ value: String) -> Bool {
        value.hasPrefix("sk-") && !value.contains(where: \.isWhitespace)
    }

    private static func upserting(key: String, inEnvContents contents: String) -> String {
        let newLine = "\(variableName)=\(formatEnvValue(key))"
        var lines = contents.components(separatedBy: .newlines)
        var replacedExistingValue = false

        for index in lines.indices {
            let trimmedLine = lines[index].trimmingCharacters(in: .whitespaces)
            var candidateLine = trimmedLine
            if candidateLine.hasPrefix("export ") {
                candidateLine = String(candidateLine.dropFirst("export ".count))
                    .trimmingCharacters(in: .whitespaces)
            }

            guard let equalsIndex = candidateLine.firstIndex(of: "=") else { continue }
            let name = String(candidateLine[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            guard name == variableName else { continue }

            let prefix = trimmedLine.hasPrefix("export ") ? "export " : ""
            lines[index] = "\(prefix)\(newLine)"
            replacedExistingValue = true
        }

        if !replacedExistingValue {
            if contents.isEmpty {
                lines = [newLine, ""]
            } else if lines.last == "" {
                lines.insert(newLine, at: lines.index(before: lines.endIndex))
            } else {
                lines.append(newLine)
                lines.append("")
            }
        }

        let updatedContents = lines.joined(separator: "\n")
        return updatedContents.hasSuffix("\n") ? updatedContents : updatedContents + "\n"
    }

    private static func formatEnvValue(_ value: String) -> String {
        let escapedValue = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapedValue)\""
    }
}

enum APIKeyStoreError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "OpenAI API keys should start with sk-."
        }
    }
}

enum TextReplacementTyper {
    static func selectAll() {
        postCommandKey(virtualKey: 0)
    }

    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = copyItems(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let replacementChangeCount = pasteboard.changeCount

        postCommandKey(virtualKey: 9)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard pasteboard.changeCount == replacementChangeCount,
                  pasteboard.string(forType: .string) == text else {
                return
            }

            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
    }

    private static func copyItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copiedItem = NSPasteboardItem()

            for type in item.types {
                if let data = item.data(forType: type) {
                    copiedItem.setData(data, forType: type)
                }
            }

            return copiedItem.types.isEmpty ? nil : copiedItem
        }
    }

    private static func postCommandKey(virtualKey: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        commandDown?.flags = .maskCommand
        commandUp?.flags = .maskCommand

        commandDown?.post(tap: .cghidEventTap)
        commandUp?.post(tap: .cghidEventTap)
    }
}
