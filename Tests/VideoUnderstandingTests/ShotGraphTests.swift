import Foundation
import Testing
@testable import VideoUnderstanding

@Test func shotGraphRequiresContinuousAuthoritativeCoverage() throws {
    let asset = VideoAssetDescriptor(
        sourceID: "fixture",
        durationSeconds: 2,
        nominalFrameRate: 30,
        frameCount: 60,
        width: 720,
        height: 1280,
        timescale: 600,
        codec: "h264",
        hasAudio: true,
        fileSizeBytes: 2_000_000,
        fingerprint: SourceFingerprint(value: "fixture-fingerprint")
    )

    let first = ShotSegment(
        id: ShotID(rawValue: "S001"),
        timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 1),
        frameRange: FrameRange(startFrame: 0, endFrameExclusive: 30),
        transitionIn: .start,
        transitionOut: .cut,
        boundaryConfidence: 0.99,
        detectorEvidenceIDs: ["detector:S001"]
    )
    let second = ShotSegment(
        id: ShotID(rawValue: "S002"),
        timeRange: MediaTimeRange(startSeconds: 1, endSeconds: 2),
        frameRange: FrameRange(startFrame: 30, endFrameExclusive: 60),
        transitionIn: .cut,
        transitionOut: .end,
        boundaryConfidence: 0.98,
        detectorEvidenceIDs: ["detector:S002"]
    )

    let graph = try ShotGraph(asset: asset, shots: [first, second])
    #expect(graph.shots.map(\.id.rawValue) == ["S001", "S002"])
    #expect(graph.coverageRatio == 1)

    let gapped = ShotSegment(
        id: ShotID(rawValue: "S002-gap"),
        timeRange: MediaTimeRange(startSeconds: 1.1, endSeconds: 2),
        frameRange: FrameRange(startFrame: 33, endFrameExclusive: 60),
        transitionIn: .cut,
        transitionOut: .end,
        boundaryConfidence: 0.9,
        detectorEvidenceIDs: ["detector:S002-gap"]
    )

    #expect(throws: ShotGraphValidationError.self) {
        _ = try ShotGraph(asset: asset, shots: [first, gapped])
    }
}
