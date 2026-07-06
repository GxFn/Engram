import Foundation
import Testing
import VideoUnderstanding
@testable import SpeechTranscription

@Test func transcriberMapsRuntimeSegmentsIntoOrderedTranscriptSegments() async throws {
    let audioURL = URL(fileURLWithPath: "/tmp/exported-audio.m4a")
    let transcriber = SpeechAnalyzerTranscriber(
        locale: Locale(identifier: "en_US"),
        audioExtractor: StaticAudioExtractor(audioURL: audioURL),
        runtime: StaticSpeechRuntime(
            segments: [
                RecognizedSpeechSegment(startSeconds: 4, endSeconds: 5.5, text: " second line "),
                RecognizedSpeechSegment(startSeconds: 0.5, endSeconds: 2, text: "First line"),
                RecognizedSpeechSegment(startSeconds: 2.1, endSeconds: 2.2, text: "  ")
            ]
        )
    )

    let segments = try await transcriber.transcribe(videoSource())

    #expect(segments == [
        TranscriptSegment(startSeconds: 0.5, endSeconds: 2, text: "First line"),
        TranscriptSegment(startSeconds: 4, endSeconds: 5.5, text: "second line")
    ])
}

@Test func segmentNormalizationKeepsTimesMonotonicAndRejectsInvalidRanges() {
    let segments = SpeechAnalyzerTranscriber.normalizedSegments(
        from: [
            RecognizedSpeechSegment(startSeconds: 2, endSeconds: 4, text: "overlap start"),
            RecognizedSpeechSegment(startSeconds: 1, endSeconds: 3, text: "first"),
            RecognizedSpeechSegment(startSeconds: 5, endSeconds: 4, text: "bad range"),
            RecognizedSpeechSegment(startSeconds: -1, endSeconds: 0.5, text: "lead in")
        ]
    )

    #expect(segments == [
        TranscriptSegment(startSeconds: 0, endSeconds: 0.5, text: "lead in"),
        TranscriptSegment(startSeconds: 1, endSeconds: 3, text: "first"),
        TranscriptSegment(startSeconds: 3, endSeconds: 4, text: "overlap start")
    ])
}

@Test func noAudioAssetsThrowNoAudioTrackBeforeRuntimeStarts() async {
    let runtime = StaticSpeechRuntime(
        segments: [
            RecognizedSpeechSegment(startSeconds: 0, endSeconds: 1, text: "should not run")
        ]
    )
    let transcriber = SpeechAnalyzerTranscriber(
        audioExtractor: ThrowingAudioExtractor(error: VideoUnderstandingError.noAudioTrack),
        runtime: runtime
    )

    await #expect(throws: VideoUnderstandingError.noAudioTrack) {
        try await transcriber.transcribe(videoSource())
    }
}

@Test func unsupportedRuntimeThrowsTranscriptionUnavailable() async {
    let transcriber = SpeechAnalyzerTranscriber(
        audioExtractor: StaticAudioExtractor(audioURL: URL(fileURLWithPath: "/tmp/exported-audio.m4a")),
        runtime: ThrowingSpeechRuntime(
            error: VideoUnderstandingError.transcriptionUnavailable("SpeechTranscriber.isAvailable is false on this runtime.")
        )
    )

    await #expect(
        throws: VideoUnderstandingError.transcriptionUnavailable("SpeechTranscriber.isAvailable is false on this runtime.")
    ) {
        try await transcriber.transcribe(videoSource())
    }
}

private func videoSource() -> VideoSource {
    VideoSource(
        id: "video-1",
        localFileURL: URL(fileURLWithPath: "/tmp/source.mov"),
        importedAt: Date(timeIntervalSince1970: 1_800_000_000),
        durationSeconds: 12
    )
}

private struct StaticAudioExtractor: VideoAudioExtracting {
    let audioURL: URL

    func audioFileURL(for videoURL: URL) async throws -> URL {
        audioURL
    }
}

private struct ThrowingAudioExtractor: VideoAudioExtracting {
    let error: Error

    func audioFileURL(for videoURL: URL) async throws -> URL {
        throw error
    }
}

private struct StaticSpeechRuntime: SpeechRecognitionRunning {
    let segments: [RecognizedSpeechSegment]

    func recognizeSegments(inAudioFileAt audioFileURL: URL, locale: Locale) async throws -> [RecognizedSpeechSegment] {
        segments
    }
}

private struct ThrowingSpeechRuntime: SpeechRecognitionRunning {
    let error: Error

    func recognizeSegments(inAudioFileAt audioFileURL: URL, locale: Locale) async throws -> [RecognizedSpeechSegment] {
        throw error
    }
}
