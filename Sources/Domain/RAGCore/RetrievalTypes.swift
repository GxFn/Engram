import Foundation

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

    public init(
        id: String,
        clipID: String,
        text: String,
        indexInClip: Int,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        preview: String? = nil
    ) {
        self.id = id
        self.clipID = clipID
        self.text = text
        self.indexInClip = indexInClip
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.preview = preview
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

/// What the Ask surface renders under an answer; tapping one must jump to the
/// original clip position (anti-hallucination rule: citations always resolve).
public struct CitationRef: Sendable, Hashable {
    public let chunkID: String
    public let clipID: String
    public let snippet: String

    public init(chunkID: String, clipID: String, snippet: String) {
        self.chunkID = chunkID
        self.clipID = clipID
        self.snippet = snippet
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
