import Foundation

public actor HybridRetriever: Retriever {
    public struct Configuration: Sendable, Hashable {
        public var denseTopK: Int
        public var keywordTopK: Int
        public var reciprocalRankK: Double
        public var citationLimit: Int

        public init(
            denseTopK: Int = 20,
            keywordTopK: Int = 20,
            reciprocalRankK: Double = 60,
            citationLimit: Int = 8
        ) {
            self.denseTopK = denseTopK
            self.keywordTopK = keywordTopK
            self.reciprocalRankK = reciprocalRankK
            self.citationLimit = citationLimit
        }

        public static let `default` = Configuration()
    }

    private let embeddingEngine: any EmbeddingEngine
    private let vectorStore: any VectorStore
    private let keywordIndex: any KeywordIndex
    private let chunkResolver: any ChunkResolver
    private let configuration: Configuration

    public init(
        embeddingEngine: any EmbeddingEngine,
        vectorStore: any VectorStore,
        keywordIndex: any KeywordIndex,
        chunkResolver: any ChunkResolver,
        configuration: Configuration = .default
    ) {
        self.embeddingEngine = embeddingEngine
        self.vectorStore = vectorStore
        self.keywordIndex = keywordIndex
        self.chunkResolver = chunkResolver
        self.configuration = configuration
    }

    public func retrieve(question: String, topK: Int = 8) async throws -> [RetrievedChunk] {
        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuestion.isEmpty else {
            return []
        }

        let vectors = try await embeddingEngine.embed([normalizedQuestion])
        guard let queryVector = vectors.first, !queryVector.isEmpty else {
            throw RetrievalError.invalidEmbeddingOutput(
                engineID: embeddingEngine.metadata.id,
                reason: "embedding query returned no vector"
            )
        }

        let dense = try await vectorStore.query(
            vector: queryVector,
            topK: max(configuration.denseTopK, 0)
        )
        let keyword = try await keywordIndex.query(
            text: normalizedQuestion,
            topK: max(configuration.keywordTopK, 0)
        )
        let fused = ReciprocalRankFusion.score(
            rankings: [dense.map(\.chunkID), keyword.map(\.chunkID)],
            k: configuration.reciprocalRankK
        )
        guard !fused.isEmpty else {
            return []
        }

        let limit = max(0, min(topK, configuration.citationLimit))
        let ranked = Array(fused.prefix(limit))
        let chunksByID = try await chunkResolver.resolve(chunkIDs: ranked.map(\.id))

        return ranked.compactMap { rankedID in
            guard let chunk = chunksByID[rankedID.id] else {
                return nil
            }
            return RetrievedChunk(
                chunk: chunk,
                score: rankedID.score,
                citation: CitationRef(
                    chunkID: chunk.id,
                    clipID: chunk.clipID,
                    snippet: Self.snippet(for: chunk)
                )
            )
        }
    }

    private nonisolated static func snippet(for chunk: Chunk) -> String {
        let source = chunk.preview?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = source
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(compact.prefix(180))
    }
}
