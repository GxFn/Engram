import Foundation
import VideoUnderstanding

public struct StoryboardShot: Sendable, Hashable, Codable {
    public let index: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let narration: String?
    public let visualDescription: String
    public let pacingNote: String?

    public init(
        index: Int,
        startSeconds: Double,
        endSeconds: Double,
        narration: String? = nil,
        visualDescription: String,
        pacingNote: String? = nil
    ) {
        self.index = index
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.narration = narration
        self.visualDescription = visualDescription
        self.pacingNote = pacingNote
    }
}

public struct Script: Sendable, Hashable, Codable {
    public let id: String
    public let videoSourceID: String
    public let title: String
    public let summary: String
    public let shots: [StoryboardShot]
    public let createdAt: Date

    public init(
        id: String,
        videoSourceID: String,
        title: String,
        summary: String,
        shots: [StoryboardShot],
        createdAt: Date
    ) {
        self.id = id
        self.videoSourceID = videoSourceID
        self.title = title
        self.summary = summary
        self.shots = shots
        self.createdAt = createdAt
    }
}

public protocol ScriptComposing: Sendable {
    func compose(
        sourceID: String,
        transcript: [TranscriptSegment],
        frames: [FrameDescription]
    ) async throws -> Script
}
