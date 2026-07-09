import Foundation
import VideoUnderstanding

public struct HookAnalysis: Sendable, Hashable, Codable {
    public let openingHook: String
    public let retentionDevices: [String]
    public let payoff: String?
    public let callToAction: String?
    public let whyItWorks: String
    /// Hook category for the personal hook library (v6). Defaults to `.other` for scripts produced
    /// before hookType existed, so old scriptJSON keeps decoding.
    public let hookType: HookType

    public init(
        openingHook: String,
        retentionDevices: [String],
        payoff: String? = nil,
        callToAction: String? = nil,
        whyItWorks: String,
        hookType: HookType = .other
    ) {
        self.openingHook = openingHook
        self.retentionDevices = retentionDevices
        self.payoff = payoff
        self.callToAction = callToAction
        self.whyItWorks = whyItWorks
        self.hookType = hookType
    }

    private enum CodingKeys: String, CodingKey {
        case openingHook, retentionDevices, payoff, callToAction, whyItWorks, hookType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openingHook = try container.decodeIfPresent(String.self, forKey: .openingHook) ?? ""
        retentionDevices = try container.decodeIfPresent([String].self, forKey: .retentionDevices) ?? []
        payoff = try container.decodeIfPresent(String.self, forKey: .payoff)
        callToAction = try container.decodeIfPresent(String.self, forKey: .callToAction)
        whyItWorks = try container.decodeIfPresent(String.self, forKey: .whyItWorks) ?? ""
        hookType = (try? container.decode(HookType.self, forKey: .hookType)) ?? .other
    }
}

public struct StoryboardShot: Sendable, Hashable, Codable {
    public let index: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let narration: String?
    public let visualDescription: String
    public let pacingNote: String?
    /// Burned-in on-screen text (字幕 / key words) for this shot, from deterministic OCR. Empty when
    /// none detected, or for scripts produced before OCR existed (decoded back-compat).
    public let onScreenText: [String]

    public init(
        index: Int,
        startSeconds: Double,
        endSeconds: Double,
        narration: String? = nil,
        visualDescription: String,
        pacingNote: String? = nil,
        onScreenText: [String] = []
    ) {
        self.index = index
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.narration = narration
        self.visualDescription = visualDescription
        self.pacingNote = pacingNote
        self.onScreenText = onScreenText
    }

    private enum CodingKeys: String, CodingKey {
        case index, startSeconds, endSeconds, narration, visualDescription, pacingNote, onScreenText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        startSeconds = try container.decode(Double.self, forKey: .startSeconds)
        endSeconds = try container.decode(Double.self, forKey: .endSeconds)
        narration = try container.decodeIfPresent(String.self, forKey: .narration)
        visualDescription = try container.decodeIfPresent(String.self, forKey: .visualDescription) ?? ""
        pacingNote = try container.decodeIfPresent(String.self, forKey: .pacingNote)
        onScreenText = try container.decodeIfPresent([String].self, forKey: .onScreenText) ?? []
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
    /// Recurring on-screen people with a consistent appearance description, so a downstream
    /// generator (豆包/即梦) can render the same 形象 across shots. Empty when transcript-only.
    public let characters: [String]
    /// Non-nil when this breakdown was produced degraded (vision failed → transcript-only, bad
    /// JSON fallback, partial deep coverage, …). Carries the human-readable reason so the UI can
    /// mark the result instead of letting it masquerade as a full 拆解. nil = clean.
    public let degradationNote: String?

    public init(
        id: String,
        videoSourceID: String,
        title: String,
        summary: String,
        shots: [StoryboardShot],
        createdAt: Date,
        hookStructure: HookAnalysis? = nil,
        visualElements: [String] = [],
        characters: [String] = [],
        degradationNote: String? = nil
    ) {
        self.id = id
        self.videoSourceID = videoSourceID
        self.title = title
        self.summary = summary
        self.shots = shots
        self.createdAt = createdAt
        self.hookStructure = hookStructure
        self.visualElements = visualElements
        self.characters = characters
        self.degradationNote = degradationNote
    }

    /// Same script, different degradation marker — the fallback paths rebuild via this so the
    /// marker survives every downstream Script reconstruction.
    public func withDegradationNote(_ note: String?) -> Script {
        Script(
            id: id,
            videoSourceID: videoSourceID,
            title: title,
            summary: summary,
            shots: shots,
            createdAt: createdAt,
            hookStructure: hookStructure,
            visualElements: visualElements,
            characters: characters,
            degradationNote: note
        )
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
        case characters
        case degradationNote
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
        characters = try container.decodeIfPresent([String].self, forKey: .characters) ?? []
        degradationNote = try container.decodeIfPresent(String.self, forKey: .degradationNote)
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
        try container.encode(characters, forKey: .characters)
        try container.encodeIfPresent(degradationNote, forKey: .degradationNote)
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
        keyframes: [SampledFrame],
        onScreenText: [FrameText]
    ) async throws -> Script
}

public extension VisionScriptComposing {
    /// Convenience for callers that have no OCR text (smoke tools / tests).
    func compose(
        sourceID: String,
        transcript: [TranscriptSegment],
        keyframes: [SampledFrame]
    ) async throws -> Script {
        try await compose(sourceID: sourceID, transcript: transcript, keyframes: keyframes, onScreenText: [])
    }
}

public protocol TextScriptComposing: Actor {
    func compose(
        sourceID: String,
        transcript: [TranscriptSegment]
    ) async throws -> Script
}
