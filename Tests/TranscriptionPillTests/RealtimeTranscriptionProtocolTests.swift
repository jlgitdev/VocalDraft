import XCTest
@testable import TranscriptionPill

final class RealtimeTranscriptionProtocolTests: XCTestCase {
    func testWebSocketURLUsesTranscriptionIntent() {
        XCTAssertEqual(
            RealtimeTranscriptionProtocol.webSocketURL()?.absoluteString,
            "wss://api.openai.com/v1/realtime?intent=transcription"
        )
    }

    func testSessionUpdateUsesTranscriptionSessionShape() throws {
        let event = RealtimeTranscriptionProtocol.sessionUpdateEvent()

        XCTAssertEqual(event["type"] as? String, "session.update")

        let session = try XCTUnwrap(event["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)

        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-realtime-whisper")
        XCTAssertEqual(transcription["language"] as? String, "en")
        XCTAssertEqual(transcription["delay"] as? String, "low")
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testCommitEventUsesInputAudioBufferCommit() {
        XCTAssertEqual(
            RealtimeTranscriptionProtocol.commitEvent()["type"] as? String,
            "input_audio_buffer.commit"
        )
    }

    func testCompletionTimeoutHasMinimumComputedValueAndCap() {
        XCTAssertEqual(
            RealtimeTranscriptionProtocol.completionTimeout(forAudioByteCount: byteCount(forSeconds: 1)),
            20
        )
        XCTAssertEqual(
            RealtimeTranscriptionProtocol.completionTimeout(forAudioByteCount: byteCount(forSeconds: 20)),
            50
        )
        XCTAssertEqual(
            RealtimeTranscriptionProtocol.completionTimeout(forAudioByteCount: byteCount(forSeconds: 80)),
            120
        )
    }

    func testTimeoutErrorMessageDoesNotPromisePartialPaste() {
        XCTAssertEqual(
            RealtimeTranscriptionProtocol.timeoutErrorMessage,
            "Transcription timed out. Try again."
        )
    }

    private func byteCount(forSeconds seconds: Double) -> Int {
        Int(24_000 * seconds) * MemoryLayout<Int16>.size
    }
}
