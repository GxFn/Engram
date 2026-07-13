import AnalysisStore
import ClipCore
import ClipDigest
import Foundation
import StoryboardCore
import Testing
import VideoUnderstanding

@Test func selectedShotPartialRerunDoesNotRequestWholeGraphKeyframes() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramStoryboardIncrementalAcceptance-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let asset = incrementalAsset()
    let graph = try incrementalGraph(asset: asset)
    let document = incrementalDocument(graph: graph)
    let selector = IncrementalRecordingKeyframeSelector()
    let provider = IncrementalUnderstandingProvider()
    let analyzer = EvidenceGroundedVideoAnalyzer(
        probe: IncrementalProbe(asset: asset),
        detector: IncrementalUnusedDetector(),
        keyframeSelector: selector,
        transcriber: IncrementalTranscriber(),
        recognizer: IncrementalOCR(),
        understandingProvider: provider,
        artifactStore: try AnalysisArtifactStore(rootURL: root),
        pipelineVersion: "incremental-acceptance"
    )
    let selectedID = graph.shots[1].id
    let source = VideoSource(
        id: asset.sourceID,
        localFileURL: URL(fileURLWithPath: "/tmp/incremental-acceptance.mp4"),
        importedAt: Date(timeIntervalSince1970: 1)
    )

    _ = try await analyzer.reanalyzeGrounded(source, document: document, shotIDs: [selectedID])

    #expect(await selector.requestedShotIDs == [[selectedID]])
    #expect(await provider.understoodShotIDs == [selectedID])
}

private actor IncrementalRecordingKeyframeSelector: ShotKeyframeSelecting {
    private(set) var requestedShotIDs: [[ShotID]] = []

    func select(in graph: ShotGraph, sourceURL: URL) async throws -> [ShotKeyframe] {
        requestedShotIDs.append(graph.shots.map(\.id))
        return graph.shots.map { shot in
            let midpoint = (shot.timeRange.startSeconds + shot.timeRange.endSeconds) / 2
            return ShotKeyframe(
                shotID: shot.id,
                frame: SampledFrame(timestampSeconds: midpoint, jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9])),
                artifactRef: "shots/\(shot.id.rawValue)/representative-1.jpg"
            )
        }
    }
}

private actor IncrementalUnderstandingProvider: ShotUnderstandingProviding {
    private(set) var understoodShotIDs: [ShotID] = []

    func understand(_ input: ShotUnderstandingInput, displayNumber: Int) async throws -> ShotUnderstandingOutput {
        understoodShotIDs.append(input.shot.id)
        return ShotUnderstandingOutput(
            shot: StoryboardShotV2(
                id: input.shot.id,
                observedFacts: ObservedShotFacts(facts: [GroundedFact(
                    field: .action,
                    value: "refreshed selected shot",
                    evidenceIDs: input.evidence.map(\.id),
                    source: .onDeviceModel,
                    confidence: 0.9
                )]),
                productionPlan: ShotProductionPlan(
                    shotID: input.shot.id,
                    displayNumber: displayNumber,
                    subjectAction: "refreshed selected shot",
                    sourceShotRefs: [input.shot.id],
                    isDerivedCreativePlan: true
                )
            )
        )
    }
}

private struct IncrementalProbe: VideoAssetProbing {
    let asset: VideoAssetDescriptor
    func probe(_ source: VideoSource) async throws -> VideoAssetDescriptor { asset }
}

private struct IncrementalUnusedDetector: ShotBoundaryDetecting {
    func detect(in asset: VideoAssetDescriptor, sourceURL: URL, quality: AnalysisQuality) async throws -> ShotGraph {
        throw IncrementalAcceptanceError.unexpectedDetectorCall
    }
}

private struct IncrementalTranscriber: Transcriber {
    func transcribe(_ source: VideoSource) async throws -> [TranscriptSegment] {
        [
            TranscriptSegment(startSeconds: 0.1, endSeconds: 0.8, text: "first shot transcript"),
            TranscriptSegment(startSeconds: 1.1, endSeconds: 1.8, text: "second shot transcript"),
        ]
    }
}

private struct IncrementalOCR: FrameTextRecognizing {
    func recognizeText(in source: VideoSource) async -> [FrameText] {
        [
            FrameText(timestampSeconds: 0.5, lines: ["FIRST"]),
            FrameText(timestampSeconds: 1.5, lines: ["SECOND"]),
        ]
    }
}

private enum IncrementalAcceptanceError: Error {
    case unexpectedDetectorCall
}

private func incrementalAsset() -> VideoAssetDescriptor {
    VideoAssetDescriptor(
        sourceID: "incremental-acceptance",
        durationSeconds: 2,
        nominalFrameRate: 30,
        frameCount: 60,
        width: 720,
        height: 1280,
        timescale: 600,
        codec: "h264",
        hasAudio: true,
        fileSizeBytes: 100,
        fingerprint: SourceFingerprint(value: "incremental-fingerprint")
    )
}

private func incrementalGraph(asset: VideoAssetDescriptor) throws -> ShotGraph {
    try ShotGraph(asset: asset, shots: [
        ShotSegment(
            id: ShotID(rawValue: "S001"),
            timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 1),
            frameRange: FrameRange(startFrame: 0, endFrameExclusive: 30),
            transitionIn: .start,
            transitionOut: .cut,
            boundaryConfidence: 0.9,
            detectorEvidenceIDs: ["detector:S001"]
        ),
        ShotSegment(
            id: ShotID(rawValue: "S002"),
            timeRange: MediaTimeRange(startSeconds: 1, endSeconds: 2),
            frameRange: FrameRange(startFrame: 30, endFrameExclusive: 60),
            transitionIn: .cut,
            transitionOut: .end,
            boundaryConfidence: 0.9,
            detectorEvidenceIDs: ["detector:S002"]
        ),
    ])
}

private func incrementalDocument(graph: ShotGraph) -> StoryboardDocumentV2 {
    StoryboardDocumentV2(
        id: "incremental-document",
        source: StoryboardSource(
            sourceID: graph.asset.sourceID,
            runID: "incremental-run",
            schemaVersion: 2,
            pipelineVersion: "incremental-acceptance",
            mode: .faithful,
            actualCloudMode: .local,
            mediaUploaded: false
        ),
        shotGraph: graph,
        shots: graph.shots.enumerated().map { index, segment in
            StoryboardShotV2(
                id: segment.id,
                observedFacts: ObservedShotFacts(facts: []),
                productionPlan: ShotProductionPlan(
                    shotID: segment.id,
                    displayNumber: index + 1,
                    subjectAction: "original \(segment.id.rawValue)",
                    sourceShotRefs: [segment.id],
                    isDerivedCreativePlan: true
                )
            )
        },
        contentAnalysis: ContentAnalysis(
            summary: "Incremental acceptance fixture",
            referencedShotIDs: graph.shots.map(\.id)
        )
    )
}
