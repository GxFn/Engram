import Testing
@testable import RAGCore

@Test func hybridRetrieverFusesDenseAndSparseResultsDeterministically() async throws {
    let chunks = [
        chunk("a", clipID: "clip-a"),
        chunk("b", clipID: "clip-b"),
        chunk("c", clipID: "clip-c"),
        chunk("d", clipID: "clip-d"),
    ]
    let retriever = HybridRetriever(
        embeddingEngine: FakeEmbedding(),
        vectorStore: FakeVectorStore(results: [
            ScoredChunk(chunkID: "a", score: 0.9),
            ScoredChunk(chunkID: "b", score: 0.8),
            ScoredChunk(chunkID: "c", score: 0.7),
        ]),
        keywordIndex: FakeKeywordIndex(results: [
            ScoredChunk(chunkID: "b", score: 100),
            ScoredChunk(chunkID: "d", score: 90),
        ]),
        chunkResolver: FakeChunkResolver(chunks: chunks)
    )

    let results = try await retriever.retrieve(question: "memory", topK: 4)

    #expect(results.map(\.chunk.id) == ["b", "a", "d", "c"])
    #expect(results.map(\.citation.clipID) == ["clip-b", "clip-a", "clip-d", "clip-c"])
}

@Test func hybridRetrieverBreaksEqualFusedScoresByChunkID() async throws {
    let retriever = HybridRetriever(
        embeddingEngine: FakeEmbedding(),
        vectorStore: FakeVectorStore(results: [ScoredChunk(chunkID: "z", score: 1)]),
        keywordIndex: FakeKeywordIndex(results: [ScoredChunk(chunkID: "a", score: 1)]),
        chunkResolver: FakeChunkResolver(chunks: [
            chunk("a", clipID: "clip-a"),
            chunk("z", clipID: "clip-z"),
        ])
    )

    let results = try await retriever.retrieve(question: "tie", topK: 2)

    #expect(results.map(\.chunk.id) == ["a", "z"])
    #expect(results.map(\.score) == [
        1.0 / 61.0,
        1.0 / 61.0,
    ])
}

@Test func hybridRetrieverDropsUnresolvedChunksAndKeepsCitationSnippets() async throws {
    let retriever = HybridRetriever(
        embeddingEngine: FakeEmbedding(),
        vectorStore: FakeVectorStore(results: [
            ScoredChunk(chunkID: "missing", score: 1),
            ScoredChunk(chunkID: "resolved", score: 0.8),
        ]),
        keywordIndex: FakeKeywordIndex(results: []),
        chunkResolver: FakeChunkResolver(chunks: [
            Chunk(
                id: "resolved",
                clipID: "clip-resolved",
                text: "Full retrieved chunk text",
                indexInClip: 0,
                preview: "Preview snippet"
            ),
        ])
    )

    let results = try await retriever.retrieve(question: "snippet", topK: 2)

    #expect(results.map(\.chunk.id) == ["resolved"])
    #expect(results.first?.citation == CitationRef(
        chunkID: "resolved",
        clipID: "clip-resolved",
        snippet: "Preview snippet"
    ))
}

private func chunk(_ id: String, clipID: String) -> Chunk {
    Chunk(id: id, clipID: clipID, text: "Text for \(id)", indexInClip: 0, preview: "Snippet \(id)")
}

private actor FakeEmbedding: EmbeddingEngine {
    nonisolated let metadata = EmbeddingEngineMetadata(
        id: "fake-embedding",
        displayName: "Fake Embedding",
        dimension: 3
    )

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0, 0] }
    }
}

private actor FakeVectorStore: VectorStore {
    let results: [ScoredChunk]

    init(results: [ScoredChunk]) {
        self.results = results
    }

    func upsert(_ entries: [(chunk: Chunk, vector: [Float])]) async throws {}

    func query(vector: [Float], topK: Int) async throws -> [ScoredChunk] {
        Array(results.prefix(topK))
    }

    func deleteClip(clipID: String) async throws {}
}

private actor FakeKeywordIndex: KeywordIndex {
    let results: [ScoredChunk]

    init(results: [ScoredChunk]) {
        self.results = results
    }

    func index(_ chunks: [Chunk]) async throws {}

    func query(text: String, topK: Int) async throws -> [ScoredChunk] {
        Array(results.prefix(topK))
    }

    func deleteClip(clipID: String) async throws {}
}

private actor FakeChunkResolver: ChunkResolver {
    private let chunks: [String: Chunk]

    init(chunks: [Chunk]) {
        self.chunks = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
    }

    func resolve(chunkIDs: [String]) async throws -> [String: Chunk] {
        chunks.filter { chunkIDs.contains($0.key) }
    }
}
