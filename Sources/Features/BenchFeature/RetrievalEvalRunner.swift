import Foundation
import RAGCore

public enum RetrievalEvalStrategy: String, CaseIterable, Identifiable, Sendable, Hashable, Codable {
    case hybrid
    case vectorOnly
    case keywordOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hybrid:
            "Hybrid"
        case .vectorOnly:
            "Vector-only"
        case .keywordOnly:
            "Keyword-only"
        }
    }
}

public struct RetrievalEvalHit: Sendable, Hashable {
    public let clipID: String
    public let chunkID: String
    public let score: Double

    public init(clipID: String, chunkID: String, score: Double) {
        self.clipID = clipID
        self.chunkID = chunkID
        self.score = score
    }
}

public struct RetrievalEvalClient: Sendable {
    public let search: @Sendable (RetrievalEvalStrategy, String, Int) async throws -> [RetrievalEvalHit]

    public init(
        search: @escaping @Sendable (RetrievalEvalStrategy, String, Int) async throws -> [RetrievalEvalHit]
    ) {
        self.search = search
    }

    public static func rag(
        hybridRetriever: any Retriever,
        embeddingEngine: any EmbeddingEngine,
        vectorStore: any VectorStore,
        keywordIndex: any KeywordIndex,
        chunkResolver: any ChunkResolver
    ) -> RetrievalEvalClient {
        RetrievalEvalClient { strategy, question, topK in
            switch strategy {
            case .hybrid:
                let results = try await hybridRetriever.retrieve(question: question, topK: topK)
                return results.map {
                    RetrievalEvalHit(
                        clipID: $0.citation.clipID,
                        chunkID: $0.citation.chunkID,
                        score: $0.score
                    )
                }

            case .vectorOnly:
                let vectors = try await embeddingEngine.embed([question])
                guard let vector = vectors.first, !vector.isEmpty else {
                    throw RetrievalError.invalidEmbeddingOutput(
                        engineID: embeddingEngine.metadata.id,
                        reason: "retrieval eval query returned no vector"
                    )
                }
                let scored = try await vectorStore.query(vector: vector, topK: topK)
                return try await hits(from: scored, chunkResolver: chunkResolver)

            case .keywordOnly:
                let scored = try await keywordIndex.query(text: question, topK: topK)
                return try await hits(from: scored, chunkResolver: chunkResolver)
            }
        }
    }

    public static func fixture(suite: RetrievalEvalSuite) -> RetrievalEvalClient {
        let chunks = suite.chunks.map(\.chunk)
        let vectorizer = RetrievalEvalLexicalVectorizer(
            corpus: chunks.map(\.text) + suite.questions.map(\.question)
        )
        let embeddingEngine = RetrievalEvalLexicalEmbeddingEngine(vectorizer: vectorizer)
        let vectorStore = RetrievalEvalInMemoryVectorStore(chunks: chunks, vectorizer: vectorizer)
        let keywordIndex = RetrievalEvalInMemoryKeywordIndex(chunks: chunks, vectorizer: vectorizer)
        let hybridRetriever = HybridRetriever(
            embeddingEngine: embeddingEngine,
            vectorStore: vectorStore,
            keywordIndex: keywordIndex,
            chunkResolver: vectorStore
        )
        return .rag(
            hybridRetriever: hybridRetriever,
            embeddingEngine: embeddingEngine,
            vectorStore: vectorStore,
            keywordIndex: keywordIndex,
            chunkResolver: vectorStore
        )
    }

    private static func hits(
        from scored: [ScoredChunk],
        chunkResolver: any ChunkResolver
    ) async throws -> [RetrievalEvalHit] {
        let chunksByID = try await chunkResolver.resolve(chunkIDs: scored.map(\.chunkID))
        return scored.compactMap { result in
            guard let chunk = chunksByID[result.chunkID] else {
                return nil
            }
            return RetrievalEvalHit(
                clipID: chunk.clipID,
                chunkID: chunk.id,
                score: result.score
            )
        }
    }
}

public struct RetrievalEvalProgress: Sendable, Hashable {
    public let completedQueries: Int
    public let totalQueries: Int
    public let strategy: RetrievalEvalStrategy
    public let questionID: String

    public init(
        completedQueries: Int,
        totalQueries: Int,
        strategy: RetrievalEvalStrategy,
        questionID: String
    ) {
        self.completedQueries = completedQueries
        self.totalQueries = totalQueries
        self.strategy = strategy
        self.questionID = questionID
    }
}

public struct RetrievalEvalQuestionResult: Sendable, Hashable {
    public let questionID: String
    public let relevantClipIDs: [String]
    public let rankedClipIDs: [String]
    public let recallAtK: Double
    public let reciprocalRank: Double

    public init(questionID: String, relevantClipIDs: [String], rankedClipIDs: [String], topK: Int) {
        self.questionID = questionID
        self.relevantClipIDs = relevantClipIDs
        self.rankedClipIDs = rankedClipIDs
        self.recallAtK = RetrievalEvalMetrics.recallAtK(
            relevantClipIDs: relevantClipIDs,
            rankedClipIDs: rankedClipIDs,
            k: topK
        )
        self.reciprocalRank = RetrievalEvalMetrics.reciprocalRank(
            relevantClipIDs: relevantClipIDs,
            rankedClipIDs: rankedClipIDs
        )
    }
}

public struct RetrievalEvalStrategyResult: Sendable, Hashable {
    public let strategy: RetrievalEvalStrategy
    public let questionResults: [RetrievalEvalQuestionResult]

    public init(strategy: RetrievalEvalStrategy, questionResults: [RetrievalEvalQuestionResult]) {
        self.strategy = strategy
        self.questionResults = questionResults
    }

    public var questionCount: Int {
        questionResults.count
    }

    public var recallAt8: Double {
        RetrievalEvalMetrics.mean(questionResults.map(\.recallAtK))
    }

    public var mrr: Double {
        RetrievalEvalMetrics.mean(questionResults.map(\.reciprocalRank))
    }
}

public struct RetrievalEvalRun: Identifiable, Sendable, Hashable {
    public let id: String
    public let startedAt: Date
    public let suiteName: String
    public let topK: Int
    public let strategyResults: [RetrievalEvalStrategyResult]

    public init(
        id: String,
        startedAt: Date,
        suiteName: String,
        topK: Int,
        strategyResults: [RetrievalEvalStrategyResult]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.suiteName = suiteName
        self.topK = topK
        self.strategyResults = strategyResults
    }

    public var questionCount: Int {
        strategyResults.first?.questionCount ?? 0
    }

    public func result(for strategy: RetrievalEvalStrategy) -> RetrievalEvalStrategyResult? {
        strategyResults.first { $0.strategy == strategy }
    }
}

public enum RetrievalEvalMetrics {
    public static func recallAtK(relevantClipIDs: [String], rankedClipIDs: [String], k: Int) -> Double {
        guard !relevantClipIDs.isEmpty, k > 0 else {
            return 0
        }
        let relevant = Set(relevantClipIDs)
        let retrieved = Set(rankedClipIDs.prefix(k))
        return Double(relevant.intersection(retrieved).count) / Double(relevant.count)
    }

    public static func reciprocalRank(relevantClipIDs: [String], rankedClipIDs: [String]) -> Double {
        let relevant = Set(relevantClipIDs)
        guard !relevant.isEmpty else {
            return 0
        }

        for (index, clipID) in rankedClipIDs.enumerated() where relevant.contains(clipID) {
            return 1.0 / Double(index + 1)
        }
        return 0
    }

    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func uniqueClipIDs(from hits: [RetrievalEvalHit]) -> [String] {
        var seen = Set<String>()
        var clipIDs: [String] = []
        for hit in hits where seen.insert(hit.clipID).inserted {
            clipIDs.append(hit.clipID)
        }
        return clipIDs
    }
}

public struct RetrievalEvalRunner: Sendable {
    public let suite: RetrievalEvalSuite
    public let client: RetrievalEvalClient
    public let topK: Int
    private let idProvider: @Sendable () -> String
    private let dateProvider: @Sendable () -> Date

    public init(
        suite: RetrievalEvalSuite,
        client: RetrievalEvalClient,
        topK: Int = 8,
        idProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        dateProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.suite = suite
        self.client = client
        self.topK = topK
        self.idProvider = idProvider
        self.dateProvider = dateProvider
    }

    public static func bundledFixture(
        topK: Int = 8,
        idProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        dateProvider: @escaping @Sendable () -> Date = Date.init
    ) throws -> RetrievalEvalRunner {
        let suite = try RetrievalEvalSuite.bundled()
        return RetrievalEvalRunner(
            suite: suite,
            client: .fixture(suite: suite),
            topK: topK,
            idProvider: idProvider,
            dateProvider: dateProvider
        )
    }

    public func run(
        progress: (@Sendable (RetrievalEvalProgress) async -> Void)? = nil
    ) async throws -> RetrievalEvalRun {
        try suite.validate()
        let strategies = RetrievalEvalStrategy.allCases
        let totalQueries = strategies.count * suite.questions.count
        var completedQueries = 0
        var strategyResults: [RetrievalEvalStrategyResult] = []

        for strategy in strategies {
            var questionResults: [RetrievalEvalQuestionResult] = []
            for question in suite.questions {
                try Task.checkCancellation()
                let hits = try await client.search(strategy, question.question, topK)
                let rankedClipIDs = RetrievalEvalMetrics.uniqueClipIDs(from: hits)
                questionResults.append(RetrievalEvalQuestionResult(
                    questionID: question.id,
                    relevantClipIDs: question.relevantClipIDs,
                    rankedClipIDs: rankedClipIDs,
                    topK: topK
                ))
                completedQueries += 1
                await progress?(RetrievalEvalProgress(
                    completedQueries: completedQueries,
                    totalQueries: totalQueries,
                    strategy: strategy,
                    questionID: question.id
                ))
            }
            strategyResults.append(RetrievalEvalStrategyResult(
                strategy: strategy,
                questionResults: questionResults
            ))
        }

        return RetrievalEvalRun(
            id: idProvider(),
            startedAt: dateProvider(),
            suiteName: "BenchSuite/retrieval-eval.json",
            topK: topK,
            strategyResults: strategyResults
        )
    }
}

private struct RetrievalEvalLexicalVectorizer: Sendable {
    private let vocabulary: [String: Int]

    var dimension: Int {
        vocabulary.count
    }

    init(corpus: [String]) {
        let tokens = Set(corpus.flatMap(Self.tokens(in:)))
        self.vocabulary = Dictionary(uniqueKeysWithValues: tokens.sorted().enumerated().map { ($0.element, $0.offset) })
    }

    func vector(for text: String) -> [Float] {
        var vector = Array(repeating: Float(0), count: vocabulary.count)
        for token in Self.tokens(in: text) {
            if let index = vocabulary[token] {
                vector[index] += 1
            }
        }
        return vector
    }

    func score(query: String, document: String) -> Double {
        let queryTokens = Set(Self.tokens(in: query))
        let documentTokens = Set(Self.tokens(in: document))
        guard !queryTokens.isEmpty, !documentTokens.isEmpty else {
            return 0
        }

        let overlap = queryTokens.intersection(documentTokens)
        let recall = Double(overlap.count) / Double(queryTokens.count)
        let precision = Double(overlap.count) / Double(documentTokens.count)
        let phraseBonus = document.localizedCaseInsensitiveContains(query) ? 0.25 : 0
        return recall + precision + phraseBonus
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return 0
        }

        var dot = Double(0)
        var leftNorm = Double(0)
        var rightNorm = Double(0)
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            leftNorm += left * left
            rightNorm += right * right
        }

        guard leftNorm > 0, rightNorm > 0 else {
            return 0
        }
        return dot / (leftNorm.squareRoot() * rightNorm.squareRoot())
    }

    private static func tokens(in text: String) -> [String] {
        let lowercased = text.lowercased()
        var tokens: [String] = []
        var current = ""

        func flushCurrent() {
            if current.count >= 2 {
                tokens.append(current)
            }
            current = ""
        }

        for scalar in lowercased.unicodeScalars {
            if isASCIIAlphaNumeric(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                flushCurrent()
                if isCJK(scalar) {
                    tokens.append(String(scalar))
                }
            }
        }
        flushCurrent()
        return tokens
    }

    private static func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
    }
}

private actor RetrievalEvalLexicalEmbeddingEngine: EmbeddingEngine {
    nonisolated let metadata: EmbeddingEngineMetadata

    private let vectorizer: RetrievalEvalLexicalVectorizer

    init(vectorizer: RetrievalEvalLexicalVectorizer) {
        self.vectorizer = vectorizer
        self.metadata = EmbeddingEngineMetadata(
            id: "retrieval-eval-lexical",
            displayName: "Retrieval Eval Lexical",
            dimension: vectorizer.dimension
        )
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { vectorizer.vector(for: $0) }
    }
}

private actor RetrievalEvalInMemoryVectorStore: VectorStore, ChunkResolver {
    private var entries: [String: (chunk: Chunk, vector: [Float])]
    private let vectorizer: RetrievalEvalLexicalVectorizer

    init(chunks: [Chunk], vectorizer: RetrievalEvalLexicalVectorizer) {
        self.vectorizer = vectorizer
        self.entries = Dictionary(uniqueKeysWithValues: chunks.map { chunk in
            (chunk.id, (chunk: chunk, vector: vectorizer.vector(for: chunk.text)))
        })
    }

    func upsert(_ entries: [(chunk: Chunk, vector: [Float])]) async throws {
        for entry in entries {
            self.entries[entry.chunk.id] = (chunk: entry.chunk, vector: entry.vector)
        }
    }

    func query(vector: [Float], topK: Int) async throws -> [ScoredChunk] {
        guard topK > 0 else {
            return []
        }

        return entries.values
            .map { entry in
                ScoredChunk(
                    chunkID: entry.chunk.id,
                    score: RetrievalEvalLexicalVectorizer.cosine(vector, entry.vector)
                )
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.chunkID < rhs.chunkID
            }
            .prefix(topK)
            .map { $0 }
    }

    func deleteClip(clipID: String) async throws {
        entries = entries.filter { $0.value.chunk.clipID != clipID }
    }

    func resolve(chunkIDs: [String]) async throws -> [String: Chunk] {
        Dictionary(uniqueKeysWithValues: chunkIDs.compactMap { chunkID in
            entries[chunkID].map { (chunkID, $0.chunk) }
        })
    }
}

private actor RetrievalEvalInMemoryKeywordIndex: KeywordIndex {
    private var chunks: [Chunk]
    private let vectorizer: RetrievalEvalLexicalVectorizer

    init(chunks: [Chunk], vectorizer: RetrievalEvalLexicalVectorizer) {
        self.chunks = chunks
        self.vectorizer = vectorizer
    }

    func index(_ chunks: [Chunk]) async throws {
        self.chunks = chunks
    }

    func query(text: String, topK: Int) async throws -> [ScoredChunk] {
        guard topK > 0 else {
            return []
        }

        return chunks
            .map { chunk in
                ScoredChunk(chunkID: chunk.id, score: vectorizer.score(query: text, document: chunk.text))
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.chunkID < rhs.chunkID
            }
            .prefix(topK)
            .map { $0 }
    }

    func deleteClip(clipID: String) async throws {
        chunks.removeAll { $0.clipID == clipID }
    }
}
