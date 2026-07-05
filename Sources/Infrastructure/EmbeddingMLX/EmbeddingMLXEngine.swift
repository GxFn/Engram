import RAGCore

/// On-device embedding via MLX (M2). First-launch model is
/// Qwen3-Embedding-0.6B, whose output dimension is 1024.
public actor EmbeddingMLXEngine: EmbeddingEngine {
    public nonisolated let dimension = 1024

    public init() {}

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        throw RetrievalError.notImplemented("M2")
    }
}
