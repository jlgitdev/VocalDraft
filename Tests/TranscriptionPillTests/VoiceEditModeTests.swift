import ApplicationServices
import CoreGraphics
import XCTest
@testable import TranscriptionPill

final class RealtimeEditProtocolTests: XCTestCase {
    func testWebSocketURLUsesRealtimeEditModel() {
        XCTAssertEqual(
            RealtimeEditProtocol.webSocketURL()?.absoluteString,
            "wss://api.openai.com/v1/realtime?model=gpt-realtime-2"
        )
    }

    func testSessionUpdateConfiguresRealtimeTextAudioInput() throws {
        let event = RealtimeEditProtocol.sessionUpdateEvent()

        XCTAssertEqual(event["type"] as? String, "session.update")

        let session = try XCTUnwrap(event["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["output_modalities"] as? [String], ["text"])
        XCTAssertTrue((session["instructions"] as? String)?.contains("Return only the final replacement text") == true)

        let reasoning = try XCTUnwrap(session["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "low")

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testSessionUpdateDoesNotUseRejectedModalitiesField() throws {
        let event = RealtimeEditProtocol.sessionUpdateEvent()
        let session = try XCTUnwrap(event["session"] as? [String: Any])

        XCTAssertNil(session["modalities"])
        XCTAssertEqual(session["output_modalities"] as? [String], ["text"])
    }

    func testContextItemEventIncludesOriginalText() throws {
        let event = RealtimeEditProtocol.contextItemEvent(originalText: "Make this better.")

        XCTAssertEqual(event["type"] as? String, "conversation.item.create")

        let item = try XCTUnwrap(event["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "message")
        XCTAssertEqual(item["role"] as? String, "user")

        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("<target_text>"))
        XCTAssertTrue(text.contains("Make this better."))
    }

    func testCommitResponseAndTimeoutEvents() {
        XCTAssertEqual(RealtimeEditProtocol.commitEvent()["type"] as? String, "input_audio_buffer.commit")

        let response = RealtimeEditProtocol.responseCreateEvent()
        XCTAssertEqual(response["type"] as? String, "response.create")
        XCTAssertEqual((response["response"] as? [String: Any])?["output_modalities"] as? [String], ["text"])

        XCTAssertEqual(
            RealtimeEditProtocol.completionTimeout(forAudioByteCount: byteCount(forSeconds: 1)),
            20
        )
        XCTAssertEqual(
            RealtimeEditProtocol.completionTimeout(forAudioByteCount: byteCount(forSeconds: 20)),
            50
        )
        XCTAssertEqual(
            RealtimeEditProtocol.completionTimeout(forAudioByteCount: byteCount(forSeconds: 80)),
            120
        )
    }

    func testSanitizedReplacementStripsCodeFencesAndProtectsNonEmptyOriginal() {
        XCTAssertEqual(
            RealtimeEditProtocol.sanitizedReplacement(from: "```text\nHello\n```", originalText: "Hi"),
            "Hello"
        )
        XCTAssertNil(RealtimeEditProtocol.sanitizedReplacement(from: " \n ", originalText: "Hi"))
        XCTAssertEqual(RealtimeEditProtocol.sanitizedReplacement(from: " \n ", originalText: ""), "")
    }

    private func byteCount(forSeconds seconds: Double) -> Int {
        Int(24_000 * seconds) * MemoryLayout<Int16>.size
    }
}

final class RealtimeEditEventParserTests: XCTestCase {
    func testDeltasCompleteOnResponseDone() {
        var parser = RealtimeEditEventParser(originalText: "hello")

        XCTAssertEqual(parser.handle(event: ["type": "response.output_text.delta", "delta": "Hi"]), .none)
        XCTAssertEqual(parser.handle(event: ["type": "response.output_text.delta", "delta": " there"]), .none)
        XCTAssertEqual(parser.handle(event: ["type": "response.done"]), .completed("Hi there"))
    }

    func testOutputTextDoneTakesPrecedenceOverDeltas() {
        var parser = RealtimeEditEventParser(originalText: "hello")

        XCTAssertEqual(parser.handle(event: ["type": "response.output_text.delta", "delta": "bad"]), .none)
        XCTAssertEqual(parser.handle(event: ["type": "response.output_text.done", "text": "good"]), .none)
        XCTAssertEqual(parser.handle(event: ["type": "response.done"]), .completed("good"))
    }

    func testResponseDoneNestedOutputFallback() {
        var parser = RealtimeEditEventParser(originalText: "hello")

        let event: [String: Any] = [
            "type": "response.done",
            "response": [
                "output": [
                    [
                        "content": [
                            [
                                "type": "output_text",
                                "text": "Nested result"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        XCTAssertEqual(parser.handle(event: event), .completed("Nested result"))
    }

    func testEmptyOutputForNonEmptyOriginalReturnsError() {
        var parser = RealtimeEditEventParser(originalText: "hello")

        XCTAssertEqual(parser.handle(event: ["type": "response.output_text.done", "text": " \n "]), .none)
        XCTAssertEqual(
            parser.handle(event: ["type": "response.done"]),
            .error(RealtimeEditProtocol.emptyReplacementErrorMessage)
        )
    }

    func testErrorEventReturnsServerMessage() {
        var parser = RealtimeEditEventParser(originalText: "hello")

        XCTAssertEqual(
            parser.handle(event: ["type": "error", "error": ["message": "Nope"]]),
            .error("Nope")
        )
    }

    func testUnknownParameterErrorSurfacesSchemaMessage() {
        var parser = RealtimeEditEventParser(originalText: "hello")

        XCTAssertEqual(
            parser.handle(event: [
                "type": "error",
                "error": [
                    "code": "unknown_parameter",
                    "message": "Unknown parameter: 'session.modalities'."
                ]
            ]),
            .error("Realtime schema error: Unknown parameter: 'session.modalities'.")
        )
    }
}

final class HotkeyStateMachineTests: XCTestCase {
    func testCommand3PressRepeatAndRelease() {
        var state = HotkeyStateMachine()

        XCTAssertEqual(state.handle(type: .keyDown, keyCode: 20, flags: .maskCommand), .press(.transcribe))
        XCTAssertEqual(state.handle(type: .keyDown, keyCode: 20, flags: .maskCommand), .none)
        XCTAssertEqual(state.handle(type: .keyUp, keyCode: 20, flags: .maskCommand), .release(.transcribe))
    }

    func testCommand4PressAndRelease() {
        var state = HotkeyStateMachine()

        XCTAssertEqual(state.handle(type: .keyDown, keyCode: 21, flags: .maskCommand), .press(.edit))
        XCTAssertEqual(state.handle(type: .keyUp, keyCode: 21, flags: .maskCommand), .release(.edit))
    }

    func testWrongModifiersDoNotTrigger() {
        var state = HotkeyStateMachine()

        XCTAssertEqual(state.handle(type: .keyDown, keyCode: 20, flags: [.maskCommand, .maskAlternate]), .none)
        XCTAssertEqual(state.handle(type: .keyDown, keyCode: 21, flags: [.maskCommand, .maskShift]), .none)
    }

    func testModifierReleaseEndsActiveHotkey() {
        var state = HotkeyStateMachine()

        XCTAssertEqual(state.handle(type: .keyDown, keyCode: 21, flags: .maskCommand), .press(.edit))
        XCTAssertEqual(state.handle(type: .flagsChanged, keyCode: 21, flags: []), .release(.edit))
    }
}

final class TextTargetPlanningTests: XCTestCase {
    func testSelectionFirstTargetSelection() {
        let resolved = TextTargetResolver.resolve(TextTargetCandidate(
            selectedText: "selected",
            selectedRange: TextRange(location: 3, length: 8),
            value: "whole selected field",
            isValueSettable: true,
            role: kAXTextFieldRole as String
        ))

        XCTAssertEqual(resolved?.kind, .selection)
        XCTAssertEqual(resolved?.originalText, "selected")
        XCTAssertEqual(resolved?.selectedRange, TextRange(location: 3, length: 8))
    }

    func testWholeFieldFallbackAllowsEmptyEditableField() {
        let resolved = TextTargetResolver.resolve(TextTargetCandidate(
            selectedText: nil,
            selectedRange: nil,
            value: "",
            isValueSettable: true,
            role: kAXTextFieldRole as String
        ))

        XCTAssertEqual(resolved?.kind, .wholeField)
        XCTAssertEqual(resolved?.originalText, "")
    }

    func testUnsupportedEmptyNonEditableFieldReturnsNil() {
        XCTAssertNil(TextTargetResolver.resolve(TextTargetCandidate(
            selectedText: nil,
            selectedRange: nil,
            value: "",
            isValueSettable: false,
            role: "AXStaticText"
        )))
    }

    func testApplyPlannerSelectionAndWholeFieldPaths() {
        let selectionTarget = ResolvedTextEditTarget(
            originalText: "selected",
            kind: .selection,
            selectedRange: TextRange(location: 2, length: 8)
        )
        XCTAssertEqual(
            TextTargetApplyPlanner.plan(
                target: selectionTarget,
                replacement: "replacement",
                isFocusedElementSame: true,
                canSetWholeValue: false
            ),
            .restoreSelectionAndPaste(range: TextRange(location: 2, length: 8), replacement: "replacement")
        )

        let wholeTarget = ResolvedTextEditTarget(originalText: "whole", kind: .wholeField, selectedRange: nil)
        XCTAssertEqual(
            TextTargetApplyPlanner.plan(
                target: wholeTarget,
                replacement: "replacement",
                isFocusedElementSame: true,
                canSetWholeValue: true
            ),
            .directSetValue("replacement")
        )
        XCTAssertEqual(
            TextTargetApplyPlanner.plan(
                target: wholeTarget,
                replacement: "replacement",
                isFocusedElementSame: true,
                canSetWholeValue: false
            ),
            .selectAllAndPaste("replacement")
        )
    }

    func testApplyPlannerAbortCases() {
        let target = ResolvedTextEditTarget(originalText: "whole", kind: .wholeField, selectedRange: nil)

        XCTAssertEqual(
            TextTargetApplyPlanner.plan(
                target: target,
                replacement: "replacement",
                isFocusedElementSame: false,
                canSetWholeValue: true
            ),
            .abortFocusChanged
        )
        XCTAssertEqual(
            TextTargetApplyPlanner.plan(
                target: target,
                replacement: "",
                isFocusedElementSame: true,
                canSetWholeValue: true
            ),
            .abortEmptyReplacement
        )
    }
}
