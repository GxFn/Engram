import AnalysisStore
import ClipCore
import ClipDigest
import Foundation
import ScriptCore
import StoryboardCore
import Testing
import VideoUnderstanding

@Test func groundedAnalyzerConnectsV2ToLegacyAndCheckpointStore() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramGroundedAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AnalysisArtifactStore(rootURL: root, now: { Date(timeIntervalSince1970: 10) })
    let source = VideoSource(
        id: "clip-grounded",
        localFileURL: URL(fileURLWithPath: "/tmp/fixture.mp4"),
        importedAt: Date(timeIntervalSince1970: 1)
    )
    let asset = groundedAsset(sourceID: source.id)
    let graph = try groundedGraph(asset: asset)
    let analyzer = EvidenceGroundedVideoAnalyzer(
        base: GroundedBaseAnalyzer(),
        probe: GroundedProbe(asset: asset),
        detector: GroundedDetector(graph: graph),
        keyframeSelector: GroundedKeyframes(shotID: graph.shots[0].id),
        artifactStore: store,
        pipelineVersion: "test-v2",
        runID: { "run-grounded" }
    )

    let result = try await analyzer.analyzeGrounded(source, onStage: { _ in })
    let resumed = try await store.loadResumableRun(
        clipID: source.id,
        fingerprint: asset.fingerprint,
        pipelineVersion: "test-v2"
    )

    #expect(result.document.source.runID == "run-grounded")
    #expect(result.document.shotGraph == graph)
    #expect(result.legacy.shots[0].startSeconds == graph.shots[0].timeRange.startSeconds)
    #expect(result.quality.evidenceLinkCoverage == 1)
    #expect(result.evidence.contains { $0.kind == .frame })
    #expect(resumed?.completedStages.contains(.quality) == true)
}

private struct GroundedBaseAnalyzer: VideoAnalyzing {
    func analyze(_ source: VideoSource, onStage: @Sendable (ClipState) async -> Void) async throws -> Script {
        Script(
            id: "legacy", videoSourceID: source.id, title: "真实标题", summary: "真实总结",
            shots: [StoryboardShot(
                index: 0, startSeconds: 0, endSeconds: 1,
                narration: "一句台词", visualDescription: "人物转身", onScreenText: ["留下"]
            )],
            createdAt: Date(timeIntervalSince1970: 5)
        )
    }
}

private struct GroundedProbe: VideoAssetProbing {
    let asset: VideoAssetDescriptor
    func probe(_ source: VideoSource) async throws -> VideoAssetDescriptor { asset }
}

private struct GroundedDetector: ShotBoundaryDetecting {
    let graph: ShotGraph
    func detect(in asset: VideoAssetDescriptor, sourceURL: URL, quality: AnalysisQuality) async throws -> ShotGraph { graph }
}

private struct GroundedKeyframes: ShotKeyframeSelecting {
    let shotID: ShotID
    func select(in graph: ShotGraph, sourceURL: URL) async throws -> [ShotKeyframe] {
        [ShotKeyframe(
            shotID: shotID,
            frame: SampledFrame(timestampSeconds: 0.5, jpegData: Data([1, 2, 3])),
            artifactRef: "shots/S001/representative.jpg"
        )]
    }
}

private func groundedAsset(sourceID: String) -> VideoAssetDescriptor {
    VideoAssetDescriptor(
        sourceID: sourceID, durationSeconds: 1, nominalFrameRate: 30, frameCount: 30,
        width: 720, height: 1280, timescale: 600, codec: "h264", hasAudio: true,
        fileSizeBytes: 3, fingerprint: SourceFingerprint(value: "grounded-fingerprint")
    )
}

private func groundedGraph(asset: VideoAssetDescriptor) throws -> ShotGraph {
    try ShotGraph(asset: asset, shots: [ShotSegment(
        id: ShotID(rawValue: "S001"),
        timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 1),
        frameRange: FrameRange(startFrame: 0, endFrameExclusive: 30),
        transitionIn: .start, transitionOut: .end, boundaryConfidence: 1,
        detectorEvidenceIDs: ["detector:S001"]
    )])
}
