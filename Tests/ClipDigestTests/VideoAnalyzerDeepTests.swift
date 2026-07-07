import ClipCore
import Foundation
import ScriptCore
import Testing
import VideoUnderstanding
@testable import ClipDigest

@Test func videoAnalyzerSegmentsLongVideosAndMerges() async throws {
    let transcript = (0..<6).map { index in
        TranscriptSegment(startSeconds: Double(index) * 100, endSeconds: Double(index) * 100 + 5, text: "seg\(index)")
    }
    let frames = (0..<6).map { index in
        SampledFrame(timestampSeconds: Double(index) * 100 + 1, jpegData: Data([0xFF, 0xD8, UInt8(index), 0xFF, 0xD9]))
    }
    let vision = DeepRecordingVisionComposer()
    let sampler = DeepRecordingFrameSampler(frames: frames)
    let analyzer = VideoAnalyzer(
        transcriber: DeepRecordingTranscriber(transcript: transcript),
        sampler: sampler,
        visionComposer: vision,
        textComposer: DeepRecordingTextComposer(),
        deep: .init(thresholdSeconds: 300, segmentWindowSeconds: 150, maxSegments: 8, framesPerSegment: 4)
    )
    let source = VideoSource(
        id: "vid",
        localFileURL: URL(fileURLWithPath: "/tmp/v.mov"),
        importedAt: Date(timeIntervalSince1970: 0),
        durationSeconds: 600
    )

    let script = try await analyzer.analyze(source) { _ in }

    let calls = await vision.calls
    #expect(calls.count == 4)                                   // ceil(600/150) = 4 segments
    #expect(calls.allSatisfy { $0.sourceID.hasPrefix("vid#seg") })
    #expect(await sampler.requests.contains(16))                // 4 segments × 4 frames
    #expect(script.videoSourceID == "vid")
    #expect(script.shots.count == 4)                            // one shot per segment, merged
    #expect(script.shots.map(\.index) == [0, 1, 2, 3])
}

@Test func videoAnalyzerUsesSingleCallForShortVideos() async throws {
    let transcript = [TranscriptSegment(startSeconds: 0, endSeconds: 5, text: "hi")]
    let vision = DeepRecordingVisionComposer()
    let analyzer = VideoAnalyzer(
        transcriber: DeepRecordingTranscriber(transcript: transcript),
        sampler: DeepRecordingFrameSampler(frames: []),
        visionComposer: vision,
        textComposer: DeepRecordingTextComposer(),
        deep: .init(thresholdSeconds: 300)
    )
    let source = VideoSource(
        id: "vid",
        localFileURL: URL(fileURLWithPath: "/tmp/v.mov"),
        importedAt: Date(timeIntervalSince1970: 0),
        durationSeconds: 30
    )

    _ = try await analyzer.analyze(source) { _ in }

    let calls = await vision.calls
    #expect(calls.count == 1)
    #expect(calls.first?.sourceID == "vid")
}

private actor DeepRecordingTranscriber: Transcriber {
    private let transcript: [TranscriptSegment]
    init(transcript: [TranscriptSegment]) { self.transcript = transcript }
    func transcribe(_ source: VideoSource) async throws -> [TranscriptSegment] { transcript }
}

private actor DeepRecordingFrameSampler: FrameSampler {
    private let frames: [SampledFrame]
    private(set) var requests: [Int] = []
    init(frames: [SampledFrame]) { self.frames = frames }
    func sampleKeyFrames(_ source: VideoSource, maxFrames: Int) async throws -> [SampledFrame] {
        requests.append(maxFrames)
        return frames
    }
}

private actor DeepRecordingVisionComposer: VisionScriptComposing {
    struct Call: Sendable {
        let sourceID: String
        let transcript: [TranscriptSegment]
        let keyframes: [SampledFrame]
    }
    private(set) var calls: [Call] = []

    func compose(
        sourceID: String,
        transcript: [TranscriptSegment],
        keyframes: [SampledFrame]
    ) async throws -> Script {
        calls.append(Call(sourceID: sourceID, transcript: transcript, keyframes: keyframes))
        let start = transcript.first?.startSeconds ?? 0
        return Script(
            id: sourceID,
            videoSourceID: sourceID,
            title: sourceID,
            summary: "s",
            shots: [StoryboardShot(index: 0, startSeconds: start, endSeconds: start + 3, narration: transcript.first?.text, visualDescription: "d", pacingNote: nil)],
            createdAt: Date(timeIntervalSince1970: 0),
            hookStructure: nil,
            visualElements: []
        )
    }
}

private actor DeepRecordingTextComposer: TextScriptComposing {
    func compose(sourceID: String, transcript: [TranscriptSegment]) async throws -> Script {
        Script(id: sourceID, videoSourceID: sourceID, title: "text", summary: "text", shots: [], createdAt: Date(timeIntervalSince1970: 0))
    }
}
