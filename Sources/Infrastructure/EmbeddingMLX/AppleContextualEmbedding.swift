import Foundation
import NaturalLanguage
import RAGCore

/// Zero-app-download embedding path backed by Apple's NaturalLanguage
/// contextual embedding assets when they are already available on device.
public actor AppleContextualEmbedding: EmbeddingEngine {
    public nonisolated let metadata: EmbeddingEngineMetadata

    private let runtime: any AppleContextualEmbeddingRuntime

    public init() {
        self.init(runtime: NaturalLanguageContextualEmbeddingRuntime())
    }

    init(runtime: any AppleContextualEmbeddingRuntime) {
        self.runtime = runtime
        self.metadata = EmbeddingEngineMetadata(
            id: "apple-natural-language-contextual",
            displayName: "Apple NaturalLanguage Contextual Embedding",
            dimension: runtime.dimension,
            modelIdentifier: runtime.modelIdentifier
        )
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        return try texts.map { text in
            try runtime.embed(text)
        }
    }
}

protocol AppleContextualEmbeddingRuntime: Sendable {
    nonisolated var dimension: Int { get }
    nonisolated var modelIdentifier: String { get }

    func embed(_ text: String) throws -> [Float]
}

final class NaturalLanguageContextualEmbeddingRuntime: AppleContextualEmbeddingRuntime, @unchecked Sendable {
    private let engineID = "apple-natural-language-contextual"
    private let embeddings: [(script: NLScript, embedding: NLContextualEmbedding)]
    private var loadedModelIdentifiers = Set<String>()

    let dimension: Int
    let modelIdentifier: String

    init() {
        let scripts: [NLScript] = [
            .latin,
            .simplifiedChinese,
            .traditionalChinese,
            .japanese,
            .korean,
        ]
        let loadedEmbeddings = scripts.compactMap { script in
            NLContextualEmbedding(script: script).map { (script: script, embedding: $0) }
        }

        self.embeddings = loadedEmbeddings
        self.dimension = loadedEmbeddings.first?.embedding.dimension ?? 0
        self.modelIdentifier = loadedEmbeddings
            .map { "\($0.script.rawValue):\($0.embedding.modelIdentifier)" }
            .joined(separator: ",")
    }

    func embed(_ text: String) throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RetrievalError.invalidEmbeddingInput("Apple contextual embedding received empty text")
        }

        guard let embedding = embedding(for: trimmed) else {
            throw RetrievalError.embeddingUnavailable(
                engineID: engineID,
                reason: "NaturalLanguage contextual embedding is unavailable for this script"
            )
        }

        guard embedding.dimension == dimension else {
            throw RetrievalError.invalidEmbeddingOutput(
                engineID: engineID,
                reason: "NaturalLanguage model dimension \(embedding.dimension) does not match engine dimension \(dimension)"
            )
        }

        guard embedding.hasAvailableAssets else {
            throw RetrievalError.embeddingUnavailable(
                engineID: engineID,
                reason: "NaturalLanguage assets are not available locally for model \(embedding.modelIdentifier); W2.6 does not request network asset downloads"
            )
        }

        do {
            if !loadedModelIdentifiers.contains(embedding.modelIdentifier) {
                try embedding.load()
                loadedModelIdentifiers.insert(embedding.modelIdentifier)
            }

            let result = try embedding.embeddingResult(for: trimmed, language: nil)
            return try Self.meanPooledNormalizedVector(
                result: result,
                expectedDimension: dimension,
                engineID: engineID
            )
        } catch let error as RetrievalError {
            throw error
        } catch {
            throw RetrievalError.embeddingUnavailable(
                engineID: engineID,
                reason: String(describing: error)
            )
        }
    }

    private func embedding(for text: String) -> NLContextualEmbedding? {
        let script = Self.dominantScript(for: text)
        return embeddings.first { $0.script == script }?.embedding
            ?? embeddings.first { $0.script == .latin }?.embedding
    }

    private static func dominantScript(for text: String) -> NLScript {
        var hanCount = 0
        var japaneseCount = 0
        var koreanCount = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                hanCount += 1
            case 0x3040...0x30FF:
                japaneseCount += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF:
                koreanCount += 1
            default:
                continue
            }
        }

        if koreanCount > max(hanCount, japaneseCount) {
            return .korean
        }
        if japaneseCount > max(hanCount, koreanCount) {
            return .japanese
        }
        if hanCount > 0 {
            return .simplifiedChinese
        }
        return .latin
    }

    private static func meanPooledNormalizedVector(
        result: NLContextualEmbeddingResult,
        expectedDimension: Int,
        engineID: String
    ) throws -> [Float] {
        var tokenCount = 0
        var sums = Array(repeating: 0.0, count: expectedDimension)

        result.enumerateTokenVectors(in: result.string.startIndex..<result.string.endIndex) { vector, _ in
            guard vector.count == expectedDimension else {
                return false
            }

            for index in 0..<expectedDimension {
                sums[index] += vector[index]
            }
            tokenCount += 1
            return true
        }

        guard tokenCount > 0 else {
            throw RetrievalError.invalidEmbeddingOutput(
                engineID: engineID,
                reason: "NaturalLanguage returned no token vectors"
            )
        }

        let mean = sums.map { $0 / Double(tokenCount) }
        let norm = sqrt(mean.reduce(0.0) { $0 + ($1 * $1) })
        guard norm.isFinite, norm > 0 else {
            throw RetrievalError.invalidEmbeddingOutput(
                engineID: engineID,
                reason: "NaturalLanguage returned a zero or non-finite pooled vector"
            )
        }

        return mean.map { Float($0 / norm) }
    }
}
