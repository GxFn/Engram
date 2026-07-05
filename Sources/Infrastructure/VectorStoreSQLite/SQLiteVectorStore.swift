import RAGCore

/// Dense index backed by SQLite + sqlite-vec (M2). Lives in the App Group
/// container so the main app and future extensions read the same index.
public actor SQLiteVectorStore: VectorStore {
    public init() {}

    public func upsert(_ entries: [(chunk: Chunk, vector: [Float])]) async throws {
        throw RetrievalError.notImplemented("M2")
    }

    public func query(vector: [Float], topK: Int) async throws -> [ScoredChunk] {
        throw RetrievalError.notImplemented("M2")
    }

    public func deleteClip(clipID: String) async throws {
        throw RetrievalError.notImplemented("M2")
    }
}

/// Sparse index backed by SQLite FTS5 (M2); fused with the dense side via
/// ReciprocalRankFusion.
public actor FTS5KeywordIndex: KeywordIndex {
    public init() {}

    public func index(_ chunks: [Chunk]) async throws {
        throw RetrievalError.notImplemented("M2")
    }

    public func query(text: String, topK: Int) async throws -> [ScoredChunk] {
        throw RetrievalError.notImplemented("M2")
    }

    public func deleteClip(clipID: String) async throws {
        throw RetrievalError.notImplemented("M2")
    }
}
