import Foundation
import VideoUnderstanding

public struct HookAnalysis: Sendable, Hashable, Codable {
    public let openingHook: String
    public let retentionDevices: [String]
    public let payoff: String?
    public let callToAction: String?
    public let whyItWorks: String

    public init(
        openingHook: String,
        retentionDevices: [String],
        payoff: String? = nil,
        callToAction: String? = nil,
        whyItWorks: String
    ) {
        self.openingHook = openingHook
        self.retentionDevices = retentionDevices
        self.payoff = payoff
        self.callToAction = callToAction
        self.whyItWorks = whyItWorks
    }
}

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
    public let hookStructure: HookAnalysis?
    public let visualElements: [String]

    public init(
        id: String,
        videoSourceID: String,
        title: String,
        summary: String,
        shots: [StoryboardShot],
        createdAt: Date,
        hookStructure: HookAnalysis? = nil,
        visualElements: [String] = []
    ) {
        self.id = id
        self.videoSourceID = videoSourceID
        self.title = title
        self.summary = summary
        self.shots = shots
        self.createdAt = createdAt
        self.hookStructure = hookStructure
        self.visualElements = visualElements
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case videoSourceID
        case title
        case summary
        case shots
        case createdAt
        case hookStructure
        case visualElements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        videoSourceID = try container.decode(String.self, forKey: .videoSourceID)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        shots = try container.decode([StoryboardShot].self, forKey: .shots)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        hookStructure = try container.decodeIfPresent(HookAnalysis.self, forKey: .hookStructure)
        visualElements = try container.decodeIfPresent([String].self, forKey: .visualElements) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(videoSourceID, forKey: .videoSourceID)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(shots, forKey: .shots)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(hookStructure, forKey: .hookStructure)
        try container.encode(visualElements, forKey: .visualElements)
    }
}

public protocol ScriptComposing: Sendable {
    func compose(
        sourceID: String,
        transcript: [TranscriptSegment],
        frames: [FrameDescription]
    ) async throws -> Script
}

public protocol VisionScriptComposing: Actor {
    func compose(
        sourceID: String,
        transcript: [TranscriptSegment],
        keyframes: [SampledFrame]
    ) async throws -> Script
}

public protocol TextScriptComposing: Actor {
    func compose(
        sourceID: String,
        transcript: [TranscriptSegment]
    ) async throws -> Script
}
