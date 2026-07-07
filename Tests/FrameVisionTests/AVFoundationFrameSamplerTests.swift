import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Testing
import VideoUnderstanding
@testable import FrameVision

@Test func samplerReturnsEmptyForNonPositiveMaxFrames() async throws {
    let sampler = AVFoundationFrameSampler(assetService: FailingFrameAssetService())

    let frames = try await sampler.sampleKeyFrames(videoSource(), maxFrames: 0)

    #expect(frames.isEmpty)
}

@Test func samplerBuildsDeterministicEvenlySpacedTimestamps() {
    #expect(AVFoundationFrameSampler.evenlySpacedTimestamps(durationSeconds: 4, maxFrames: 4) == [0.5, 1.5, 2.5, 3.5])
    #expect(AVFoundationFrameSampler.evenlySpacedTimestamps(durationSeconds: 3, maxFrames: 1) == [1.5])
    #expect(AVFoundationFrameSampler.evenlySpacedTimestamps(durationSeconds: 0, maxFrames: 3).isEmpty)
    #expect(AVFoundationFrameSampler.evenlySpacedTimestamps(durationSeconds: 4, maxFrames: 0).isEmpty)
}

@Test func samplerExtractsMonotonicJPEGSFromGeneratedMovie() async throws {
    let videoURL = try makeGeneratedMovie(frameRate: 4, frameCount: 8)
    defer { try? FileManager.default.removeItem(at: videoURL) }

    let sampler = AVFoundationFrameSampler()

    let frames = try await sampler.sampleKeyFrames(videoSource(url: videoURL), maxFrames: 4)

    #expect(frames.count == 4)
    #expect(frames.allSatisfy { !$0.jpegData.isEmpty })
    #expect(frames.allSatisfy { $0.jpegData.starts(with: [0xFF, 0xD8]) })
    #expect(frames.map(\.timestampSeconds) == frames.map(\.timestampSeconds).sorted())
    #expect(frames.first?.timestampSeconds ?? -1 >= 0)
    #expect(frames.last?.timestampSeconds ?? 10 <= 2)
}

@Test func samplerClassifiesNoVideoTrackAsUnreadableAsset() async {
    let sampler = AVFoundationFrameSampler(
        assetService: StaticFrameAssetService(videoTrackCount: 0, durationSeconds: 3)
    )

    await expectUnreadableAsset(containing: "No video track found") {
        _ = try await sampler.sampleKeyFrames(videoSource(), maxFrames: 3)
    }
}

@Test func samplerClassifiesInvalidDurationAsUnreadableAsset() async {
    let sampler = AVFoundationFrameSampler(
        assetService: StaticFrameAssetService(videoTrackCount: 1, durationSeconds: 0)
    )

    await expectUnreadableAsset(containing: "Invalid video duration") {
        _ = try await sampler.sampleKeyFrames(videoSource(), maxFrames: 3)
    }
}

@Test func samplerClassifiesImageGenerationFailureAsUnreadableAsset() async {
    let sampler = AVFoundationFrameSampler(
        assetService: StaticFrameAssetService(
            videoTrackCount: 1,
            durationSeconds: 3,
            sampleError: FixtureError.imageGenerationFailed
        )
    )

    await expectUnreadableAsset(containing: "imageGenerationFailed") {
        _ = try await sampler.sampleKeyFrames(videoSource(), maxFrames: 3)
    }
}

private func videoSource(url: URL = URL(fileURLWithPath: "/tmp/source.mov")) -> VideoSource {
    VideoSource(
        id: "video-1",
        localFileURL: url,
        importedAt: Date(timeIntervalSince1970: 1_800_000_000),
        durationSeconds: 2
    )
}

private func expectUnreadableAsset(
    containing expectedText: String,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected VideoUnderstandingError.unreadableAsset.")
    } catch let error as VideoUnderstandingError {
        guard case let .unreadableAsset(message) = error else {
            Issue.record("Expected unreadableAsset, got \(error).")
            return
        }

        #expect(message.contains(expectedText))
    } catch {
        Issue.record("Expected VideoUnderstandingError, got \(error).")
    }
}

private struct StaticFrameAssetService: FrameAssetServicing {
    let videoTrackCount: Int
    let durationSeconds: Double
    var sampleError: Error?

    init(videoTrackCount: Int, durationSeconds: Double, sampleError: Error? = nil) {
        self.videoTrackCount = videoTrackCount
        self.durationSeconds = durationSeconds
        self.sampleError = sampleError
    }

    func videoTrackCount(for videoURL: URL) async throws -> Int {
        videoTrackCount
    }

    func durationSeconds(for videoURL: URL) async throws -> Double {
        durationSeconds
    }

    func sampleFrames(at timestamps: [Double], from videoURL: URL) async throws -> [GeneratedFrame] {
        if let sampleError {
            throw sampleError
        }

        return timestamps.map { timestamp in
            GeneratedFrame(timestampSeconds: timestamp, jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        }
    }
}

private struct FailingFrameAssetService: FrameAssetServicing {
    func videoTrackCount(for videoURL: URL) async throws -> Int {
        Issue.record("Non-positive maxFrames should not inspect video tracks.")
        return 1
    }

    func durationSeconds(for videoURL: URL) async throws -> Double {
        Issue.record("Non-positive maxFrames should not inspect duration.")
        return 1
    }

    func sampleFrames(at timestamps: [Double], from videoURL: URL) async throws -> [GeneratedFrame] {
        Issue.record("Non-positive maxFrames should not generate frames.")
        return []
    }
}

private enum FixtureError: Error {
    case imageGenerationFailed
}

private func makeGeneratedMovie(frameRate: Int32, frameCount: Int) throws -> URL {
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-frame-sampler-\(UUID().uuidString)")
        .appendingPathExtension("mov")

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 96,
        AVVideoHeightKey: 64,
        AVVideoCompressionPropertiesKey: [
            AVVideoMaxKeyFrameIntervalKey: 1
        ]
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 96,
            kCVPixelBufferHeightKey as String: 64
        ]
    )

    #expect(writer.canAdd(input))
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    for frameIndex in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.001)
        }

        let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: frameRate)
        guard adaptor.append(try pixelBuffer(frameIndex: frameIndex), withPresentationTime: presentationTime) else {
            throw writer.error ?? FixtureError.imageGenerationFailed
        }
    }

    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: frameRate))

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
        semaphore.signal()
    }
    semaphore.wait()

    if writer.status != .completed {
        throw writer.error ?? FixtureError.imageGenerationFailed
    }

    return outputURL
}

private func pixelBuffer(frameIndex: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        96,
        64,
        kCVPixelFormatType_32ARGB,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw FixtureError.imageGenerationFailed
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw FixtureError.imageGenerationFailed
    }

    let byteCount = CVPixelBufferGetDataSize(pixelBuffer)
    let color = UInt8(30 + (frameIndex * 23) % 200)
    baseAddress.assumingMemoryBound(to: UInt8.self).initialize(repeating: color, count: byteCount)

    return pixelBuffer
}
