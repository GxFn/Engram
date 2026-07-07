import Foundation
import ScriptCore
import Testing
import VideoUnderstanding

@Test func visionScriptComposingIsPublicAndActorImplementable() async throws {
    let composer: any VisionScriptComposing = FixtureVisionComposer()
    let transcript = [
        TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "Opening line"),
        TranscriptSegment(startSeconds: 2, endSeconds: 4, text: "Action beat")
    ]
    let keyframes = [
        SampledFrame(timestampSeconds: 0.5, jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9])),
        SampledFrame(timestampSeconds: 2.5, jpegData: Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9]))
    ]

    let script = try await composer.compose(
        sourceID: "vision-source",
        transcript: transcript,
        keyframes: keyframes
    )

    #expect(script.videoSourceID == "vision-source")
    #expect(script.summary == "2 transcript segments, 2 keyframes.")
    #expect(script.shots.count == 2)
    #expect(script.shots[0].narration == "Opening line")
    #expect(script.shots[0].visualDescription == "Keyframe at 0.5s with 4 bytes.")
}

@Test func textScriptComposingIsPublicAndActorImplementable() async throws {
    let composer: any TextScriptComposing = FixtureTextComposer()
    let transcript = [
        TranscriptSegment(startSeconds: 1, endSeconds: 3.5, text: "A transcript-only fallback.")
    ]

    let script = try await composer.compose(sourceID: "text-source", transcript: transcript)

    #expect(script.videoSourceID == "text-source")
    #expect(script.title == "Text fallback")
    #expect(script.shots == [
        StoryboardShot(
            index: 0,
            startSeconds: 1,
            endSeconds: 3.5,
            narration: "A transcript-only fallback.",
            visualDescription: "",
            pacingNote: "Transcript-only fallback"
        )
    ])
}

@Test func composerContractAdditionsDoNotRegressIndexableText() async throws {
    let composer: any VisionScriptComposing = FixtureVisionComposer()
    let script = try await composer.compose(
        sourceID: "render-source",
        transcript: [
            TranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Show the product.")
        ],
        keyframes: [
            SampledFrame(timestampSeconds: 0.5, jpegData: Data([0xFF, 0xD8]))
        ]
    )

    #expect(ScriptRendering.indexableText(script).components(separatedBy: "\n\n") == [
        "Vision storyboard",
        "1 transcript segments, 1 keyframes.",
        "## 分镜 1 (0.5s–1.5s)\n台词: Show the product.\n画面: Keyframe at 0.5s with 2 bytes.\n节奏: Vision beat"
    ])
}

private actor FixtureVisionComposer: VisionScriptComposing {
    func compose(
        sourceID: String,
        transcript: [TranscriptSegment],
        keyframes: [SampledFrame]
    ) async throws -> Script {
        let shots = keyframes.enumerated().map { index, frame in
            StoryboardShot(
                index: index,
                startSeconds: frame.timestampSeconds,
                endSeconds: frame.timestampSeconds + 1,
                narration: transcript[safe: index]?.text,
                visualDescription: "Keyframe at \(format(frame.timestampSeconds)) with \(frame.jpegData.count) bytes.",
                pacingNote: "Vision beat"
            )
        }

        return Script(
            id: "vision-script",
            videoSourceID: sourceID,
            title: "Vision storyboard",
            summary: "\(transcript.count) transcript segments, \(keyframes.count) keyframes.",
            shots: shots,
            createdAt: Date(timeIntervalSince1970: 2_600)
        )
    }
}

private actor FixtureTextComposer: TextScriptComposing {
    func compose(sourceID: String, transcript: [TranscriptSegment]) async throws -> Script {
        let shots = transcript.enumerated().map { index, segment in
            StoryboardShot(
                index: index,
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                narration: segment.text,
                visualDescription: "",
                pacingNote: "Transcript-only fallback"
            )
        }

        return Script(
            id: "text-script",
            videoSourceID: sourceID,
            title: "Text fallback",
            summary: "\(transcript.count) transcript segments.",
            shots: shots,
            createdAt: Date(timeIntervalSince1970: 2_700)
        )
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func format(_ seconds: Double) -> String {
    let roundedTenths = Int((seconds * 10).rounded())
    let wholeSeconds = roundedTenths / 10
    let tenths = roundedTenths % 10

    if tenths == 0 {
        return "\(wholeSeconds)s"
    }

    return "\(wholeSeconds).\(tenths)s"
}
