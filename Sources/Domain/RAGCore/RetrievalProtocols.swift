public protocol Chunker: Sendable {
    func chunk(clipID: String, text: String, config: ChunkingConfig) -> [Chunk]
}

/// On-device embedding backend (M2: Qwen3-Embedding via MLX).
public protocol EmbeddingEngine: Actor {
    nonisolated var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
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
