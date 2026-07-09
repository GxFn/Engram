import AVFoundation
import CoreGraphics
import EngramLogging
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoUnderstanding

public struct AVFoundationFrameSampler: FrameSampler {
    private let assetService: any FrameAssetServicing
    private let candidateMultiplier: Int
    private let candidateCap: Int

    public init() {
        self.init(assetService: AVFoundationFrameAssetService())
    }

    init(
        assetService: any FrameAssetServicing,
        candidateMultiplier: Int = 5,
        candidateCap: Int = 40
    ) {
        self.assetService = assetService
        self.candidateMultiplier = max(1, candidateMultiplier)
        self.candidateCap = max(1, candidateCap)
    }

    public func sampleKeyFrames(_ source: VideoSource, maxFrames: Int) async throws -> [SampledFrame] {
        guard maxFrames > 0 else {
            return []
        }

        do {
            let videoTrackCount = try await assetService.videoTrackCount(for: source.localFileURL)
            guard videoTrackCount > 0 else {
                throw VideoUnderstandingError.unreadableAsset(
                    "No video track found in \(source.localFileURL.lastPathComponent)."
                )
            }

            let durationSeconds = try await assetService.durationSeconds(for: source.localFileURL)
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                throw VideoUnderstandingError.unreadableAsset(
                    "Invalid video duration for \(source.localFileURL.lastPathComponent): \(durationSeconds)."
                )
            }

            // Scene-aware sampling: over-sample a denser candidate set, then keep the maxFrames
            // most visually distinct (farthest-point selection over cheap thumbnail signatures).
            // Evenly-spaced snapshots miss scene cuts; distinct-frame selection covers the actual
            // shots. Falls back to even subsampling when signatures cannot be computed.
            let candidateCount = min(max(maxFrames * candidateMultiplier, maxFrames), candidateCap)
            let candidateTimestamps = Self.evenlySpacedTimestamps(
                durationSeconds: durationSeconds,
                maxFrames: candidateCount
            )
            let generatedFrames = try await assetService.sampleFrames(
                at: candidateTimestamps,
                from: source.localFileURL
            )

            let candidates = try generatedFrames
                .map { frame in
                    guard frame.timestampSeconds.isFinite, frame.timestampSeconds >= 0 else {
                        throw VideoUnderstandingError.unreadableAsset(
                            "Generated frame has an invalid timestamp for \(source.localFileURL.lastPathComponent)."
                        )
                    }
                    guard !frame.jpegData.isEmpty else {
                        throw VideoUnderstandingError.unreadableAsset(
                            "Generated frame has empty JPEG data for \(source.localFileURL.lastPathComponent)."
                        )
                    }
                    return SampledFrame(timestampSeconds: frame.timestampSeconds, jpegData: frame.jpegData)
                }
                .sorted { lhs, rhs in lhs.timestampSeconds < rhs.timestampSeconds }

            guard candidates.count > maxFrames else {
                return candidates
            }

            return Self.selectSceneAware(candidates, maxFrames: maxFrames)
        } catch let error as VideoUnderstandingError {
            throw error
        } catch {
            Log.frameVision.error("Frame sampling failed for \(source.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw VideoUnderstandingError.unreadableAsset(
                "Unable to sample frames from \(source.localFileURL.lastPathComponent): \(String(describing: error))"
            )
        }
    }

    static func evenlySpacedTimestamps(durationSeconds: Double, maxFrames: Int) -> [Double] {
        guard maxFrames > 0, durationSeconds.isFinite, durationSeconds > 0 else {
            return []
        }

        let interval = durationSeconds / Double(maxFrames)
        return (0..<maxFrames).map { index in
            (Double(index) + 0.5) * interval
        }
    }

    /// Keeps the `maxFrames` most visually distinct candidates (assumed sorted by time),
    /// preserving chronological order in the result.
    static func selectSceneAware(_ frames: [SampledFrame], maxFrames: Int) -> [SampledFrame] {
        guard frames.count > maxFrames, maxFrames > 0 else {
            return frames
        }

        let signatures = frames.map { FrameSignatureExtractor.signature(fromJPEG: $0.jpegData) }
        guard signatures.allSatisfy({ $0 != nil }) else {
            // Undecodable frames (e.g. non-image data): fall back to deterministic even subsampling.
            return evenlySubsampled(frames, count: maxFrames)
        }

        let vectors = signatures.compactMap { $0 }

        // Drop near-solid frames (black dips, flashes, fades): in signature space they're extreme
        // outliers, so farthest-point selection would PREFER them — wasting scarce frame budget on
        // empty frames. Conservative threshold; never filter below the requested budget.
        let eligible = vectors.indices.filter {
            FrameSignatureExtractor.lumaVariance(vectors[$0]) >= 0.0015
        }
        let pool = eligible.count >= maxFrames ? eligible : Array(vectors.indices)

        let selectedInPool = SceneAwareFrameSelection.select(
            signatures: pool.map { vectors[$0] },
            maxFrames: maxFrames
        )
        return selectedInPool.map { pool[$0] }.sorted().map { frames[$0] }
    }

    static func evenlySubsampled(_ frames: [SampledFrame], count: Int) -> [SampledFrame] {
        guard count > 0, frames.count > count else {
            return frames
        }
        let step = Double(frames.count) / Double(count)
        return (0..<count).map { index in
            frames[min(frames.count - 1, Int((Double(index) + 0.5) * step))]
        }
    }
}

/// Farthest-point selection over frame signatures: greedily keeps the frames that are most
/// mutually distinct, approximating one representative frame per visually distinct scene.
enum SceneAwareFrameSelection {
    static func select(signatures: [[Float]], maxFrames: Int) -> [Int] {
        let count = signatures.count
        guard maxFrames > 0 else { return [] }
        guard count > maxFrames else { return Array(0..<count) }

        var selected = [0]
        var minDistance = signatures.map { distanceSquared($0, signatures[0]) }
        minDistance[0] = -1

        while selected.count < maxFrames {
            var bestIndex = -1
            var bestDistance = -Double.greatestFiniteMagnitude
            for index in 0..<count where minDistance[index] >= 0 {
                if minDistance[index] > bestDistance {
                    bestDistance = minDistance[index]
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { break }
            selected.append(bestIndex)
            minDistance[bestIndex] = -1
            for index in 0..<count where minDistance[index] >= 0 {
                minDistance[index] = min(minDistance[index], distanceSquared(signatures[index], signatures[bestIndex]))
            }
        }

        return selected
    }

    static func distanceSquared(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count else { return 0 }
        var sum = 0.0
        for index in 0..<lhs.count {
            let delta = Double(lhs[index] - rhs[index])
            sum += delta * delta
        }
        return sum
    }
}

/// Cheap perceptual signature: a 16×16 RGB thumbnail flattened to normalized [r,g,b] per pixel.
/// Color-aware (a red end-card vs a blue studio at the same brightness are distinct scenes the old
/// grayscale signature couldn't tell apart); enough for farthest-point selection, not a precise
/// fingerprint.
enum FrameSignatureExtractor {
    static func signature(fromJPEG data: Data, side: Int = 16) -> [Float]? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: side, height: side))
        var vector = [Float]()
        vector.reserveCapacity(side * side * 3)
        for pixel in 0 ..< (side * side) {
            let offset = pixel * 4
            vector.append(Float(pixels[offset]) / 255.0)     // r
            vector.append(Float(pixels[offset + 1]) / 255.0) // g
            vector.append(Float(pixels[offset + 2]) / 255.0) // b
        }
        return vector
    }

    /// Luma variance over an [r,g,b,…] signature — near zero for solid/black/flash frames.
    static func lumaVariance(_ signature: [Float]) -> Double {
        guard signature.count >= 3 else { return 0 }
        var lumas: [Double] = []
        lumas.reserveCapacity(signature.count / 3)
        var index = 0
        while index + 2 < signature.count {
            lumas.append(
                0.299 * Double(signature[index])
                    + 0.587 * Double(signature[index + 1])
                    + 0.114 * Double(signature[index + 2])
            )
            index += 3
        }
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        return lumas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)
    }
}

struct GeneratedFrame: Sendable, Equatable {
    let timestampSeconds: Double
    let jpegData: Data
}

protocol FrameAssetServicing: Sendable {
    func videoTrackCount(for videoURL: URL) async throws -> Int
    func durationSeconds(for videoURL: URL) async throws -> Double
    func sampleFrames(at timestamps: [Double], from videoURL: URL) async throws -> [GeneratedFrame]
}

struct AVFoundationFrameAssetService: FrameAssetServicing {
    func videoTrackCount(for videoURL: URL) async throws -> Int {
        let asset = AVURLAsset(url: videoURL)
        return try await asset.loadTracks(withMediaType: .video).count
    }

    func durationSeconds(for videoURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        return duration.seconds
    }

    func sampleFrames(at timestamps: [Double], from videoURL: URL) async throws -> [GeneratedFrame] {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frames: [GeneratedFrame] = []
        frames.reserveCapacity(timestamps.count)

        for timestamp in timestamps {
            let requestedTime = CMTime(seconds: timestamp, preferredTimescale: 600)
            do {
                let result = try await generator.image(at: requestedTime)
                let actualSeconds = result.actualTime.seconds
                guard actualSeconds.isFinite, actualSeconds >= 0 else {
                    throw VideoUnderstandingError.unreadableAsset(
                        "AVAssetImageGenerator returned an invalid timestamp for \(videoURL.lastPathComponent)."
                    )
                }

                frames.append(
                    GeneratedFrame(
                        timestampSeconds: actualSeconds,
                        jpegData: try Self.jpegData(from: result.image, sourceName: videoURL.lastPathComponent)
                    )
                )
            } catch let error as VideoUnderstandingError {
                throw error
            } catch {
                throw VideoUnderstandingError.unreadableAsset(
                    "Unable to generate frame at \(timestamp) seconds from \(videoURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }

        return frames
    }

    private static func jpegData(from image: CGImage, sourceName: String) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw VideoUnderstandingError.unreadableAsset("Unable to create JPEG destination for \(sourceName).")
        }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw VideoUnderstandingError.unreadableAsset("Unable to finalize JPEG data for \(sourceName).")
        }

        let jpegData = data as Data
        guard !jpegData.isEmpty else {
            throw VideoUnderstandingError.unreadableAsset("Generated empty JPEG data for \(sourceName).")
        }

        return jpegData
    }
}
