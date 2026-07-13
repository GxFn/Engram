import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoUnderstanding

public struct ShotFrameSignal: Codable, Hashable, Sendable {
    public let frame: Int
    public let timestampSeconds: Double
    public let histogram: [Double]
    public let luma: Double
    public let edgeEnergy: Double
    public let blackRatio: Double

    public init(frame: Int, timestampSeconds: Double, histogram: [Double], luma: Double, edgeEnergy: Double, blackRatio: Double) {
        self.frame = frame
        self.timestampSeconds = timestampSeconds
        self.histogram = histogram
        self.luma = luma
        self.edgeEnergy = edgeEnergy
        self.blackRatio = blackRatio
    }
}

public struct AdaptiveShotBoundaryDetector: Sendable {
    public init() {}

    public func detect(signals: [ShotFrameSignal], asset: VideoAssetDescriptor) throws -> ShotGraph {
        let ordered = signals.sorted { $0.frame < $1.frame }
        guard !ordered.isEmpty else { throw VideoUnderstandingError.unreadableAsset("shot detector received no frames") }
        var boundaries: [(frame: Int, confidence: Double)] = []
        var recent: [Double] = []
        var lastBoundary = 0
        let minimumShotFrames = max(3, Int((asset.nominalFrameRate * 0.25).rounded()))

        for index in 1..<ordered.count {
            let previous = ordered[index - 1]
            let current = ordered[index]
            let histogramDelta = zip(previous.histogram, current.histogram).reduce(0) { $0 + abs($1.0 - $1.1) }
                / Double(max(1, min(previous.histogram.count, current.histogram.count)))
            let score = histogramDelta + abs(previous.luma - current.luma) * 0.6
                + abs(previous.edgeEnergy - current.edgeEnergy) * 0.2
            let median = Self.median(recent)
            let mad = Self.median(recent.map { abs($0 - median) })
            let threshold = max(0.32, median + max(0.08, mad * 6))
            let flashOrBlack = current.blackRatio > 0.95 || previous.blackRatio > 0.95
            if score >= threshold, !flashOrBlack, current.frame - lastBoundary >= minimumShotFrames {
                boundaries.append((current.frame, min(1, score / max(threshold, 0.001))))
                lastBoundary = current.frame
            }
            recent.append(score)
            if recent.count > 16 { recent.removeFirst() }
        }

        let frameCount = asset.frameCount ?? max(1, Int((asset.durationSeconds * asset.nominalFrameRate).rounded()))
        let usable = boundaries.filter { $0.frame > 0 && $0.frame < frameCount }
        let starts = [0] + usable.map(\.frame)
        let ends = usable.map(\.frame) + [frameCount]
        let shots = zip(starts, ends).enumerated().map { index, pair in
            let isFirst = index == 0
            let isLast = index == starts.count - 1
            let confidence = isLast ? 1 : usable[index].confidence
            return ShotSegment(
                id: ShotID(rawValue: String(format: "S%03d-%d-%d", index + 1, pair.0, pair.1)),
                timeRange: MediaTimeRange(
                    startSeconds: Double(pair.0) / asset.nominalFrameRate,
                    endSeconds: isLast ? asset.durationSeconds : Double(pair.1) / asset.nominalFrameRate
                ),
                frameRange: FrameRange(startFrame: pair.0, endFrameExclusive: pair.1),
                transitionIn: isFirst ? .start : .cut,
                transitionOut: isLast ? .end : .cut,
                boundaryConfidence: confidence,
                detectorEvidenceIDs: ["adaptive:\(pair.0)-\(pair.1)"]
            )
        }
        return try ShotGraph(asset: asset, shots: shots)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

public struct AVFoundationVideoAssetProbe: VideoAssetProbing {
    public init() {}

    public func probe(_ source: VideoSource) async throws -> VideoAssetDescriptor {
        let asset = AVURLAsset(url: source.localFileURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoUnderstandingError.unreadableAsset("video track missing")
        }
        let duration = try await asset.load(.duration).seconds
        let fps = Double(try await track.load(.nominalFrameRate))
        let size = try await track.load(.naturalSize)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let bytes = ((try FileManager.default.attributesOfItem(atPath: source.localFileURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let data = try Data(contentsOf: source.localFileURL, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return VideoAssetDescriptor(
            sourceID: source.id, durationSeconds: duration, nominalFrameRate: fps,
            frameCount: max(1, Int((duration * fps).rounded())), width: Int(abs(size.width)), height: Int(abs(size.height)),
            timescale: 600, codec: nil, hasAudio: !audio.isEmpty, fileSizeBytes: bytes,
            fingerprint: SourceFingerprint(value: hash)
        )
    }
}

public struct AVFoundationShotBoundaryDetector: ShotBoundaryDetecting {
    private let detector: AdaptiveShotBoundaryDetector
    public init(detector: AdaptiveShotBoundaryDetector = .init()) { self.detector = detector }

    public func detect(in asset: VideoAssetDescriptor, sourceURL: URL, quality: AnalysisQuality) async throws -> ShotGraph {
        let rate: Double = quality == .fast ? 4 : (quality == .accurate ? 10 : 6)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        var signals: [ShotFrameSignal] = []
        var time = 0.0
        while time < asset.durationSeconds {
            let requested = CMTime(seconds: time, preferredTimescale: 600)
            var actual = CMTime.zero
            let image = try generator.copyCGImage(at: requested, actualTime: &actual)
            signals.append(Self.signal(image: image, time: actual.seconds, fps: asset.nominalFrameRate))
            time += 1 / rate
        }
        return try detector.detect(signals: signals, asset: asset)
    }

    private static func signal(image: CGImage, time: Double, fps: Double) -> ShotFrameSignal {
        let width = 16, height = 16
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var histogram = [Double](repeating: 0, count: 16)
        for pixel in pixels { histogram[min(15, Int(pixel) / 16)] += 1 / Double(pixels.count) }
        let luma = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count * 255)
        let black = Double(pixels.filter { $0 < 12 }.count) / Double(pixels.count)
        var edge = 0.0
        for index in 1..<pixels.count { edge += abs(Double(pixels[index]) - Double(pixels[index - 1])) }
        return ShotFrameSignal(frame: max(0, Int((time * fps).rounded())), timestampSeconds: time,
                               histogram: histogram, luma: luma, edgeEnergy: edge / Double(pixels.count * 255), blackRatio: black)
    }
}

public struct AVFoundationShotKeyframeSelector: ShotKeyframeSelecting {
    public init() {}
    public func select(in graph: ShotGraph, sourceURL: URL) async throws -> [ShotKeyframe] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        generator.appliesPreferredTrackTransform = true
        return try graph.shots.map { shot in
            let time = (shot.timeRange.startSeconds + shot.timeRange.endSeconds) / 2
            var actual = CMTime.zero
            let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: &actual)
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw VideoUnderstandingError.visionUnavailable("jpeg encoder unavailable")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw VideoUnderstandingError.visionUnavailable("jpeg encode failed") }
            return ShotKeyframe(shotID: shot.id, frame: SampledFrame(timestampSeconds: actual.seconds, jpegData: data as Data),
                                artifactRef: "shots/\(shot.id.rawValue)/representative.jpg")
        }
    }
}
