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

@Test func adaptiveDetectorSuppressesSingleFrameHighMotionBurst() throws {
    let asset = detectorAsset(sourceID: "synthetic-high-motion", frameCount: 90)
    let signals = (0..<90).map { frame -> ShotFrameSignal in
        if frame == 30 {
            return detectorSignal(
                frame: frame,
                histogram: [0.45, 0.55],
                luma: 0.5,
                edgeEnergy: 1
            )
        }
        return detectorSignal(frame: frame)
    }

    let graph = try AdaptiveShotBoundaryDetector().detect(signals: signals, asset: asset)

    #expect(graph.shots.count == 1)
    #expect(graph.shots[0].frameRange == FrameRange(startFrame: 0, endFrameExclusive: 90))
}

@Test func adaptiveDetectorSuppressesBrightFlash() throws {
    let asset = detectorAsset(sourceID: "synthetic-bright-flash", frameCount: 90)
    let signals = (0..<90).map { frame -> ShotFrameSignal in
        if frame == 30 {
            return detectorSignal(
                frame: frame,
                histogram: [0, 1],
                luma: 1,
                edgeEnergy: 0.05,
                blackRatio: 0
            )
        }
        return detectorSignal(frame: frame)
    }

    let graph = try AdaptiveShotBoundaryDetector().detect(signals: signals, asset: asset)

    #expect(graph.shots.count == 1)
    #expect(graph.shots[0].transitionOut == .end)
}

@Test func adaptiveDetectorSuppressesBlackFrameBurst() throws {
    let asset = detectorAsset(sourceID: "synthetic-black-burst", frameCount: 90)
    let signals = (0..<90).map { frame -> ShotFrameSignal in
        if (30...31).contains(frame) {
            return detectorSignal(
                frame: frame,
                histogram: [1, 0],
                luma: 0,
                edgeEnergy: 0,
                blackRatio: 0.99
            )
        }
        return detectorSignal(frame: frame)
    }

    let graph = try AdaptiveShotBoundaryDetector().detect(signals: signals, asset: asset)

    #expect(graph.shots.count == 1)
    #expect(graph.coverageRatio == 1)
}

@Test func adaptiveDetectorPreservesRealCutAfterHighMotionAndFlashNoise() throws {
    let asset = detectorAsset(sourceID: "synthetic-noisy-real-cut", frameCount: 90)
    let signals = (0..<90).map { frame -> ShotFrameSignal in
        if frame == 20 {
            return detectorSignal(
                frame: frame,
                histogram: [0.45, 0.55],
                luma: 0.5,
                edgeEnergy: 1
            )
        }
        if frame == 30 {
            return detectorSignal(
                frame: frame,
                histogram: [0, 1],
                luma: 1,
                edgeEnergy: 0.05
            )
        }
        if frame >= 45 {
            return detectorSignal(
                frame: frame,
                histogram: [0, 1],
                luma: 0.8,
                edgeEnergy: 0.2
            )
        }
        return detectorSignal(frame: frame)
    }

    let graph = try AdaptiveShotBoundaryDetector().detect(signals: signals, asset: asset)

    #expect(graph.shots.count == 2)
    #expect(graph.shots[0].frameRange == FrameRange(startFrame: 0, endFrameExclusive: 45))
    #expect(graph.shots[0].transitionOut == .cut)
    #expect(graph.shots[1].frameRange == FrameRange(startFrame: 45, endFrameExclusive: 90))
}

private func detectorAsset(sourceID: String, frameCount: Int) -> VideoAssetDescriptor {
    VideoAssetDescriptor(
        sourceID: sourceID,
        durationSeconds: Double(frameCount) / 30,
        nominalFrameRate: 30,
        frameCount: frameCount,
        width: 320,
        height: 180,
        timescale: 600,
        codec: "synthetic",
        hasAudio: false,
        fileSizeBytes: 1,
        fingerprint: SourceFingerprint(value: sourceID)
    )
}

private func detectorSignal(
    frame: Int,
    histogram: [Double] = [0.85, 0.15],
    luma: Double = 0.25,
    edgeEnergy: Double = 0.2,
    blackRatio: Double = 0
) -> ShotFrameSignal {
    ShotFrameSignal(
        frame: frame,
        timestampSeconds: Double(frame) / 30,
        histogram: histogram,
        luma: luma,
        edgeEnergy: edgeEnergy,
        blackRatio: blackRatio
    )
}
