import AVFoundation
import CoreGraphics
import EngramLogging
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoUnderstanding

public struct AVFoundationFrameSampler: FrameSampler {
    private let assetService: any FrameAssetServicing

    public init() {
        self.init(assetService: AVFoundationFrameAssetService())
    }

    init(assetService: any FrameAssetServicing) {
        self.assetService = assetService
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

            let requestedTimestamps = Self.evenlySpacedTimestamps(
                durationSeconds: durationSeconds,
                maxFrames: maxFrames
            )
            let generatedFrames = try await assetService.sampleFrames(
                at: requestedTimestamps,
                from: source.localFileURL
            )

            return try generatedFrames
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
