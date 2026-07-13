import Foundation

public struct StoryboardCitationAnchor: Sendable, Hashable, Codable {
    public let displayNumber: Int
    public let startSeconds: Double
    public let endSeconds: Double

    public init(displayNumber: Int, startSeconds: Double, endSeconds: Double) {
        self.displayNumber = displayNumber
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// One indexed slice of a clip's body text.
public struct Chunk: Sendable, Hashable, Codable {
    public let id: String
    public let clipID: String
    public let text: String
    /// Position within the clip, used to rebuild citation context in order.
    public let indexInClip: Int
    /// Character offset into the source clip body for the first included character.
    public let startOffset: Int?
    /// Character offset just after the last included source character.
    public let endOffset: Int?
    /// Compact display text for future indexing/debug surfaces.
    public let preview: String?
    /// Exact shot/time anchors parsed from the deterministic storyboard rendering.
    public let storyboardAnchors: [StoryboardCitationAnchor]

    public init(
        id: String,
        clipID: String,
        text: String,
        indexInClip: Int,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        preview: String? = nil,
        storyboardAnchors: [StoryboardCitationAnchor] = []
    ) {
        self.id = id
        self.clipID = clipID
        self.text = text
        self.indexInClip = indexInClip
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.preview = preview
        self.storyboardAnchors = storyboardAnchors
    }

    private enum CodingKeys: String, CodingKey {
        case id, clipID, text, indexInClip, startOffset, endOffset, preview, storyboardAnchors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        clipID = try container.decode(String.self, forKey: .clipID)
        text = try container.decode(String.self, forKey: .text)
        indexInClip = try container.decode(Int.self, forKey: .indexInClip)
        startOffset = try container.decodeIfPresent(Int.self, forKey: .startOffset)
        endOffset = try container.decodeIfPresent(Int.self, forKey: .endOffset)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        storyboardAnchors = try container.decodeIfPresent([StoryboardCitationAnchor].self, forKey: .storyboardAnchors) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(clipID, forKey: .clipID)
        try container.encode(text, forKey: .text)
        try container.encode(indexInClip, forKey: .indexInClip)
        try container.encodeIfPresent(startOffset, forKey: .startOffset)
        try container.encodeIfPresent(endOffset, forKey: .endOffset)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encode(storyboardAnchors, forKey: .storyboardAnchors)
    }
}

public struct ChunkingConfig: Sendable, Hashable {
    public var targetCharacters: Int
    public var overlapCharacters: Int

    public init(targetCharacters: Int = 800, overlapCharacters: Int = 120) {
        self.targetCharacters = targetCharacters
        self.overlapCharacters = overlapCharacters
    }
}

public struct ScoredChunk: Sendable, Hashable {
    public let chunkID: String
    public let score: Double

    public init(chunkID: String, score: Double) {
        self.chunkID = chunkID
        self.score = score
    }
}

public struct RankedID<ID: Hashable & Comparable & Sendable>: Sendable, Hashable {
    public let id: ID
    public let score: Double

    public init(id: ID, score: Double) {
        self.id = id
        self.score = score
    }
}

/// What the Ask surface renders under an answer; tapping one must jump to the
/// original clip position (anti-hallucination rule: citations always resolve).
public struct CitationRef: Sendable, Hashable {
    public let chunkID: String
    public let clipID: String
    public let snippet: String
    public let storyboardAnchors: [StoryboardCitationAnchor]

    public init(chunkID: String, clipID: String, snippet: String, storyboardAnchors: [StoryboardCitationAnchor] = []) {
        self.chunkID = chunkID
        self.clipID = clipID
        self.snippet = snippet
        self.storyboardAnchors = storyboardAnchors
    }
}

public struct RetrievedChunk: Sendable, Hashable {
    public let chunk: Chunk
    public let score: Double
    public let citation: CitationRef

    public init(chunk: Chunk, score: Double, citation: CitationRef) {
        self.chunk = chunk
        self.score = score
        self.citation = citation
    }
}

public enum RetrievalError: Error, Sendable {
    /// Placeholder used by infrastructure stubs; the payload names the roadmap milestone.
    case notImplemented(String)
    /// A local engine exists, but the current platform/runtime/assets cannot run it.
    case embeddingUnavailable(engineID: String, reason: String)
    /// A configured local embedding model has no verified payload in the model store.
    case embeddingModelNotDownloaded(modelID: String, expectedPath: String)
    /// A local embedding model payload exists but failed during runtime load.
    case embeddingModelLoadFailed(modelID: String, reason: String)
    /// The caller supplied text that cannot produce a meaningful embedding.
    case invalidEmbeddingInput(String)
    /// The runtime produced a vector count, dimension, or value that cannot be indexed.
    case invalidEmbeddingOutput(engineID: String, reason: String)
}
