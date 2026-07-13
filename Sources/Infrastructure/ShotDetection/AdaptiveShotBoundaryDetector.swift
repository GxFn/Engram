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
        var boundaries: [(frame: Int, confidence: Double, transition: ShotTransition)] = []
        var recent: [Double] = []
        var lastBoundary = 0
        let minimumShotFrames = max(3, Int((asset.nominalFrameRate * 0.25).rounded()))
        var gradualStart: Int?
        var gradualScore = 0.0
        var suppressedReboundIndex: Int?

        for index in 1..<ordered.count {
            let previous = ordered[index - 1]
            let current = ordered[index]
            let score = Self.distance(previous, current)
            let median = Self.median(recent)
            let mad = Self.median(recent.map { abs($0 - median) })
            let threshold = max(0.32, median + max(0.08, mad * 6))
            let blackFrame = current.blackRatio > 0.95 || previous.blackRatio > 0.95
            let startsTransientDisturbance = ordered.indices.contains(index + 1)
                && Self.isTransientDisturbance(
                    previous: previous,
                    current: current,
                    next: ordered[index + 1],
                    candidateScore: score
                )
            if startsTransientDisturbance {
                // A one-frame flash or motion spike creates a second large delta when the
                // original scene returns. Neither edge is an authoritative shot boundary.
                suppressedReboundIndex = index + 1
            }
            let transientDisturbance = startsTransientDisturbance || suppressedReboundIndex == index
            if suppressedReboundIndex == index { suppressedReboundIndex = nil }
            if score >= threshold, !blackFrame, !transientDisturbance,
               current.frame - lastBoundary >= minimumShotFrames {
                boundaries.append((current.frame, min(1, score / max(threshold, 0.001)), .cut))
                lastBoundary = current.frame
                gradualStart = nil
                gradualScore = 0
            } else if score >= 0.025, score < threshold {
                gradualStart = gradualStart ?? (index - 1)
                gradualScore += score
            } else if let start = gradualStart {
                let count = index - start
                if count >= 4, gradualScore >= 0.18 {
                    let window = Array(ordered[start...index])
                    let darkest = window.enumerated().min(by: { $0.element.luma < $1.element.luma })
                    let isFade = (darkest?.element.luma ?? 1) < 0.16
                    let candidate = isFade
                        ? (darkest?.element.frame ?? window[window.count / 2].frame)
                        : window[window.count / 2].frame
                    if candidate - lastBoundary >= minimumShotFrames {
                        boundaries.append((candidate, min(0.95, gradualScore), isFade ? .fade : .dissolve))
                        lastBoundary = candidate
                    }
                }
                gradualStart = nil
                gradualScore = 0
            }
            recent.append(score)
            if recent.count > 16 { recent.removeFirst() }
        }

        let frameCount = asset.frameCount ?? max(1, Int((asset.durationSeconds * asset.nominalFrameRate).rounded()))
        let usable = boundaries
            .filter { $0.frame > 0 && $0.frame < frameCount }
            .sorted { $0.frame < $1.frame }
        let starts = [0] + usable.map(\.frame)
        let ends = usable.map(\.frame) + [frameCount]
        let shots = zip(starts, ends).enumerated().map { index, pair in
            let isFirst = index == 0
            let isLast = index == starts.count - 1
            let confidence = isLast ? 1 : usable[index].confidence
            let transitionIn = isFirst ? ShotTransition.start : usable[index - 1].transition
            let transitionOut = isLast ? ShotTransition.end : usable[index].transition
            return ShotSegment(
                id: ShotID(rawValue: String(format: "S%03d-%d-%d", index + 1, pair.0, pair.1)),
                timeRange: MediaTimeRange(
                    startSeconds: Double(pair.0) / asset.nominalFrameRate,
                    endSeconds: isLast ? asset.durationSeconds : Double(pair.1) / asset.nominalFrameRate
                ),
                frameRange: FrameRange(startFrame: pair.0, endFrameExclusive: pair.1),
                transitionIn: transitionIn,
                transitionOut: transitionOut,
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

    static func distance(_ previous: ShotFrameSignal, _ current: ShotFrameSignal) -> Double {
        let histogramDelta = zip(previous.histogram, current.histogram).reduce(0) { $0 + abs($1.0 - $1.1) }
            / Double(max(1, min(previous.histogram.count, current.histogram.count)))
        return histogramDelta + abs(previous.luma - current.luma) * 0.6
            + abs(previous.edgeEnergy - current.edgeEnergy) * 0.2
    }

    private static func isTransientDisturbance(
        previous: ShotFrameSignal,
        current: ShotFrameSignal,
        next: ShotFrameSignal,
        candidateScore: Double
    ) -> Bool {
        guard candidateScore >= 0.32 else { return false }
        let returnToPrevious = distance(previous, next)
        let leavesTransientFrame = distance(current, next)
        return returnToPrevious <= max(0.12, candidateScore * 0.35)
            && leavesTransientFrame >= candidateScore * 0.55
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
        let coarse = try detector.detect(signals: signals, asset: asset)
        return try Self.refine(coarse, generator: generator, asset: asset, sampleRate: rate)
    }

    private static func refine(
        _ graph: ShotGraph,
        generator: AVAssetImageGenerator,
        asset: VideoAssetDescriptor,
        sampleRate: Double
    ) throws -> ShotGraph {
        guard graph.shots.count > 1 else { return graph }
        let frameCount = asset.frameCount ?? max(1, Int((asset.durationSeconds * asset.nominalFrameRate).rounded()))
        let radius = max(2, Int((asset.nominalFrameRate / sampleRate).rounded(.up)))
        var boundaries: [(frame: Int, transition: ShotTransition, confidence: Double)] = []
        for index in 1..<graph.shots.count {
            let candidate = graph.shots[index].frameRange.startFrame
            let lower = max(1, candidate - radius)
            let upper = min(frameCount - 1, candidate + radius)
            var local: [ShotFrameSignal] = []
            for frame in (lower - 1)...upper {
                let requested = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(asset.nominalFrameRate.rounded()))
                var actual = CMTime.zero
                let image = try generator.copyCGImage(at: requested, actualTime: &actual)
                local.append(signal(image: image, time: actual.seconds, fps: asset.nominalFrameRate))
            }
            let transition = graph.shots[index].transitionIn
            let refined: Int
            if transition == .fade {
                refined = local.min(by: { $0.luma < $1.luma })?.frame ?? candidate
            } else if transition == .dissolve {
                refined = local[local.count / 2].frame
            } else {
                refined = zip(local, local.dropFirst()).max(by: {
                    AdaptiveShotBoundaryDetector.distance($0.0, $0.1) < AdaptiveShotBoundaryDetector.distance($1.0, $1.1)
                })?.1.frame ?? candidate
            }
            boundaries.append((max(lower, min(upper, refined)), transition, graph.shots[index - 1].boundaryConfidence))
        }
        let starts = [0] + boundaries.map(\.frame)
        let ends = boundaries.map(\.frame) + [frameCount]
        let shots = zip(starts, ends).enumerated().map { index, pair in
            let first = index == 0
            let last = index == starts.count - 1
            return ShotSegment(
                id: ShotID(rawValue: String(format: "S%03d-%d-%d", index + 1, pair.0, pair.1)),
                timeRange: MediaTimeRange(
                    startSeconds: Double(pair.0) / asset.nominalFrameRate,
                    endSeconds: last ? asset.durationSeconds : Double(pair.1) / asset.nominalFrameRate
                ),
                frameRange: FrameRange(startFrame: pair.0, endFrameExclusive: pair.1),
                transitionIn: first ? .start : boundaries[index - 1].transition,
                transitionOut: last ? .end : boundaries[index].transition,
                boundaryConfidence: last ? 1 : boundaries[index].confidence,
                detectorEvidenceIDs: ["adaptive-refined:\(pair.0)-\(pair.1)"]
            )
        }
        return try ShotGraph(asset: asset, shots: shots)
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
        try await select(
            in: graph,
            sourceURL: sourceURL,
            shotIDs: Set(graph.shots.map(\.id)),
            framesPerShot: 1
        )
    }

    public func select(
        in graph: ShotGraph,
        sourceURL: URL,
        shotIDs: Set<ShotID>,
        framesPerShot: Int
    ) async throws -> [ShotKeyframe] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        generator.appliesPreferredTrackTransform = true
        let count = min(3, max(1, framesPerShot))
        var selected: [ShotKeyframe] = []
        for shot in graph.shots where shotIDs.contains(shot.id) {
            let frames = Self.representativeFrames(for: shot, requestedCount: count)
            for (index, frame) in frames.enumerated() {
                let time = Double(frame) / graph.asset.nominalFrameRate
                var actual = CMTime.zero
                let image = try generator.copyCGImage(
                    at: CMTime(seconds: time, preferredTimescale: 600),
                    actualTime: &actual
                )
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw VideoUnderstandingError.visionUnavailable("jpeg encoder unavailable")
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw VideoUnderstandingError.visionUnavailable("jpeg encode failed")
                }
                selected.append(ShotKeyframe(
                    shotID: shot.id,
                    frame: SampledFrame(timestampSeconds: actual.seconds, jpegData: data as Data),
                    artifactRef: "shots/\(shot.id.rawValue)/representative-\(index + 1).jpg"
                ))
            }
        }
        return selected
    }

    static func representativeFrames(for shot: ShotSegment, requestedCount: Int) -> [Int] {
        let count = min(3, max(1, requestedCount))
        let first = shot.frameRange.startFrame
        let last = max(first, shot.frameRange.endFrameExclusive - 1)
        let available = last - first + 1
        let actualCount = min(count, available)
        guard actualCount > 1 else { return [(first + last) / 2] }
        let safeInset = available > actualCount + 2 ? 1 : 0
        let safeFirst = first + safeInset
        let safeLast = last - safeInset
        return (0..<actualCount).map { index in
            let ratio = Double(index) / Double(actualCount - 1)
            return Int((Double(safeFirst) + Double(safeLast - safeFirst) * ratio).rounded())
        }
    }
}
