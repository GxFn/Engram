public protocol Chunker: Sendable {
    func chunk(clipID: String, text: String, config: ChunkingConfig) -> [Chunk]
}

/// Stable embedding identity recorded with vector indexes so engine switches
/// can force a rebuild instead of mixing incompatible vectors.
public struct EmbeddingEngineMetadata: Sendable, Hashable, Codable {
    public let id: String
    public let displayName: String
    public let dimension: Int
    public let modelIdentifier: String?

    public init(
        id: String,
        displayName: String,
        dimension: Int,
        modelIdentifier: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.dimension = dimension
        self.modelIdentifier = modelIdentifier
    }
}

/// On-device embedding backend.
public protocol EmbeddingEngine: Actor {
    nonisolated var metadata: EmbeddingEngineMetadata { get }
    nonisolated var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public extension EmbeddingEngine {
    nonisolated var dimension: Int {
        metadata.dimension
    }
}

/// Dense retrieval half of hybrid search (M2: SQLite-vec).
public protocol VectorStore: Actor {
    func upsert(_ entries: [(chunk: Chunk, vector: [Float])]) async throws
    func query(vector: [Float], topK: Int) async throws -> [ScoredChunk]
    func deleteClip(clipID: String) async throws
}

/// Sparse retrieval half of hybrid search (M2: FTS5/BM25).
public protocol KeywordIndex: Actor {
    func index(_ chunks: [Chunk]) async throws
    func query(text: String, topK: Int) async throws -> [ScoredChunk]
    func deleteClip(clipID: String) async throws
}

/// Resolves ranked ids back to source chunks so every Ask citation can carry
/// real clip/chunk data instead of an unreachable display stub.
public protocol ChunkResolver: Actor {
    func resolve(chunkIDs: [String]) async throws -> [String: Chunk]
}

public protocol Retriever: Actor {
    func retrieve(question: String, topK: Int) async throws -> [RetrievedChunk]
}
