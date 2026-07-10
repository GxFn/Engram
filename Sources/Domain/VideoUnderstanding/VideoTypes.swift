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

/// On-screen text (burned-in 字幕 / captions / key words) recognized in the frame at `timestampSeconds`.
/// Deterministic OCR output — kept separate from the VLM so the text is captured regardless of backend.
public struct FrameText: Sendable, Hashable, Codable {
    public let timestampSeconds: Double
    public let lines: [String]

    public init(timestampSeconds: Double, lines: [String]) {
        self.timestampSeconds = timestampSeconds
        self.lines = lines
    }
}

public protocol Transcriber: Sendable {
    func transcribe(_ source: VideoSource) async throws -> [TranscriptSegment]
}

public protocol TranscriptCorrecting: Sendable {
    /// Cleans raw ASR output (typos, homophones, missing punctuation, run-ons) without changing
    /// meaning, preserving each segment's timing. `onScreenText` carries the burned-in 字幕 read by
    /// OCR — the creator's own authoritative captions — so domain terms the ASR mishears
    /// (电竞/人名/战队 etc.) can be corrected against them. Implementations return the original
    /// segments on any non-cancellation failure so the pipeline never breaks.
    func correct(_ segments: [TranscriptSegment], onScreenText: [FrameText]) async throws -> [TranscriptSegment]
}

extension TranscriptCorrecting {
    /// Convenience for callers without captions.
    public func correct(_ segments: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        try await correct(segments, onScreenText: [])
    }
}

public protocol FrameSampler: Sendable {
    func sampleKeyFrames(_ source: VideoSource, maxFrames: Int) async throws -> [SampledFrame]
}

public protocol VisionDescriber: Sendable {
    func describe(_ frames: [SampledFrame]) async throws -> [FrameDescription]
}

/// Recognizes on-screen text (burned-in 字幕 / captions) across a video, densely enough that caption
/// changes aren't missed, and de-duplicated so a caption held across frames isn't repeated.
/// Implementations must never throw — return an empty array on any failure so 拆解 still proceeds.
public protocol FrameTextRecognizing: Sendable {
    func recognizeText(in source: VideoSource) async -> [FrameText]
}

public enum VideoUnderstandingError: Error, Sendable, Hashable, Codable {
    case noAudioTrack
    case transcriptionUnavailable(String)
    case visionUnavailable(String)
    /// Hard vision-backend configuration failure (missing API key, auth rejection): the user must
    /// fix Settings, so this must surface as a retryable failure — degrading to a transcript-only
    /// "success" would hide the misconfiguration behind a green Indexed state.
    case visionConfigurationInvalid(String)
    case unreadableAsset(String)
}
