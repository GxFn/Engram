import ShotDetection
import Testing
import VideoUnderstanding

@Test func adaptiveDetectorBuildsAuthoritativeGraphFromSignalCut() throws {
    let asset = VideoAssetDescriptor(
        sourceID: "synthetic-cut", durationSeconds: 2, nominalFrameRate: 30,
        frameCount: 60, width: 320, height: 180, timescale: 600,
        codec: "synthetic", hasAudio: false, fileSizeBytes: 1,
        fingerprint: SourceFingerprint(value: "synthetic")
    )
    let signals = (0..<60).map { frame in
        ShotFrameSignal(
            frame: frame,
            timestampSeconds: Double(frame) / 30,
            histogram: frame < 30 ? [1, 0, 0, 0] : [0, 0, 0, 1],
            luma: frame < 30 ? 0.2 : 0.8,
            edgeEnergy: 0.4,
            blackRatio: 0
        )
    }

    let graph = try AdaptiveShotBoundaryDetector().detect(signals: signals, asset: asset)

    #expect(graph.shots.count == 2)
    #expect(graph.shots[0].frameRange == FrameRange(startFrame: 0, endFrameExclusive: 30))
    #expect(graph.shots[1].frameRange == FrameRange(startFrame: 30, endFrameExclusive: 60))
    #expect(graph.shots[0].transitionOut == .cut)
}
