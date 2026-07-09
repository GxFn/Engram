import Foundation

public struct VideoSource: Sendable, Hashable, Codable {
    public let id: String
    public let localFileURL: URL
    public let importedAt: Date
    public var durationSeconds: Double?

    public init(
        id: String,
        localFileURL: URL,
        importedAt: Date,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.localFileURL = localFileURL
        self.importedAt = importedAt
        self.durationSeconds = durationSeconds
    }
}

public struct TranscriptSegment: Sendable, Hashable, Codable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

public struct SampledFrame: Sendable, Hashable, Codable {
    public let timestampSeconds: Double
    public let jpegData: Data

    public init(timestampSeconds: Double, jpegData: Data) {
        self.timestampSeconds = timestampSeconds
        self.jpegData = jpegData
    }
}

public struct FrameDescription: Sendable, Hashable, Codable {
    public let timestampSeconds: Double
    public let description: String

    public init(timestampSeconds: Double, description: String) {
        self.timestampSeconds = timestampSeconds
        self.description = description
    }
}

public protocol Transcriber: Sendable {
    func transcribe(_ source: VideoSource) async throws -> [TranscriptSegment]
}

public protocol TranscriptCorrecting: Sendable {
    /// Cleans raw ASR output (typos, homophones, missing punctuation, run-ons) without changing
    /// meaning, preserving each segment's timing. Implementations return the original segments on
    /// any non-cancellation failure so the pipeline never breaks.
    func correct(_ segments: [TranscriptSegment]) async throws -> [TranscriptSegment]
}

public protocol FrameSampler: Sendable {
    func sampleKeyFrames(_ source: VideoSource, maxFrames: Int) async throws -> [SampledFrame]
}

public protocol VisionDescriber: Sendable {
    func describe(_ frames: [SampledFrame]) async throws -> [FrameDescription]
}

public enum VideoUnderstandingError: Error, Sendable, Hashable, Codable {
    case noAudioTrack
    case transcriptionUnavailable(String)
    case visionUnavailable(String)
    case unreadableAsset(String)
}
