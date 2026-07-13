import ShotDetection
import Foundation
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

@Test func realVideoProbeDetectorAndKeyframeSmoke() async throws {
    guard let path = ProcessInfo.processInfo.environment["ENGRAM_REAL_VIDEO"] else { return }
    let url = URL(fileURLWithPath: path)
    let source = VideoSource(
        id: "real-video-smoke",
        localFileURL: url,
        importedAt: Date(timeIntervalSince1970: 0)
    )

    let asset = try await AVFoundationVideoAssetProbe().probe(source)
    let graph = try await AVFoundationShotBoundaryDetector().detect(
        in: asset,
        sourceURL: url,
        quality: .fast
    )
    let keyframes = try await AVFoundationShotKeyframeSelector().select(in: graph, sourceURL: url)

    #expect(asset.durationSeconds > 12)
    #expect(asset.frameCount == 385)
    #expect(graph.coverageRatio == 1)
    #expect(!graph.shots.isEmpty)
    #expect(keyframes.count == graph.shots.count)
    #expect(keyframes.allSatisfy { $0.frame.jpegData.starts(with: [0xff, 0xd8]) })
}

@Test func adaptiveDetectorClassifiesGradualFade() throws {
    let asset = VideoAssetDescriptor(
        sourceID: "synthetic-fade", durationSeconds: 2, nominalFrameRate: 30,
        frameCount: 60, width: 320, height: 180, timescale: 600,
        codec: "synthetic", hasAudio: false, fileSizeBytes: 1,
        fingerprint: SourceFingerprint(value: "fade")
    )
    let signals = (0..<60).map { frame -> ShotFrameSignal in
        let progress = frame < 20 ? 0.8 : (frame <= 35 ? 0.8 - Double(frame - 20) * 0.05 : 0.05)
        return ShotFrameSignal(
            frame: frame,
            timestampSeconds: Double(frame) / 30,
            histogram: [progress, 1 - progress],
            luma: progress,
            edgeEnergy: progress * 0.3,
            blackRatio: progress < 0.08 ? 0.98 : 0
        )
    }

    let graph = try AdaptiveShotBoundaryDetector().detect(signals: signals, asset: asset)

    #expect(graph.shots.contains { $0.transitionOut == .fade })
    #expect(graph.coverageRatio == 1)
}
