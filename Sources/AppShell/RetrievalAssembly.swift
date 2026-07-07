import AppGroupSupport
import ClipDigest
import EmbeddingMLX
import EngineKit
import Foundation
import FrameVision
import ModelStore
import RAGCore
import ScriptComposer
import SpeechTranscription
import SwiftData
import VectorStoreSQLite

struct RetrievalServices: Sendable {
    let clipDigestService: ClipDigestService
    let retriever: any Retriever
}

enum RetrievalAssembly {
    static let defaultVideoTranscriptionLocale = Locale(identifier: "zh_CN")

    private static let videoAnalyzerMaxFrames = 6

    @MainActor
    static func makeServices(
        modelContainer: ModelContainer,
        modelStore: ModelStore,
        activeEngine: any LLMEngine,
        activeModel: ModelIdentity,
        generationConfig: GenerationConfig,
        videoAnalyzer: (any VideoAnalyzing)? = nil,
        appGroupLocations: AppGroupLocations? = nil,
        embeddingEngine: (any EmbeddingEngine)? = nil
    ) throws -> RetrievalServices {
        let locations: AppGroupLocations
        if let appGroupLocations {
            locations = appGroupLocations
        } else {
            locations = try EngramAppGroup.locations()
        }

        let embeddingEngine: any EmbeddingEngine = embeddingEngine ?? AppleContextualEmbedding()
        let configuration = SQLiteIndexConfiguration.file(
            locations.retrievalIndexURL,
            embeddingEngineID: embeddingEngine.metadata.id,
            expectedDimension: embeddingEngine.dimension
        )
        let vectorStore = SQLiteVectorStore(configuration: configuration)
        let keywordIndex = FTS5KeywordIndex(configuration: configuration)
        let indexer = ClipRetrievalIndexer(
            chunker: ParagraphChunker(),
            embeddingEngine: embeddingEngine,
            vectorStore: vectorStore,
            keywordIndex: keywordIndex
        )
        let retriever = HybridRetriever(
            embeddingEngine: embeddingEngine,
            vectorStore: vectorStore,
            keywordIndex: keywordIndex,
            chunkResolver: vectorStore
        )
        let videoAnalyzer = videoAnalyzer ?? makeVideoAnalyzer(
            modelStore: modelStore,
            activeEngine: activeEngine,
            activeModel: activeModel,
            generationConfig: generationConfig
        )
        let digestService = try ClipDigestService.live(
            modelContainer: modelContainer,
            indexer: indexer,
            videoAnalyzer: videoAnalyzer,
            locations: locations
        )
        return RetrievalServices(
            clipDigestService: digestService,
            retriever: retriever
        )
    }

    private static func makeVideoAnalyzer(
        modelStore: ModelStore,
        activeEngine: any LLMEngine,
        activeModel: ModelIdentity,
        generationConfig: GenerationConfig
    ) -> any VideoAnalyzing {
        let textConfiguration = ScriptComposerConfiguration(
            maxKeyframeCount: 0,
            generationConfig: generationConfig
        )
        let textComposer = TextScriptComposer(
            engine: activeEngine,
            model: activeModel,
            configuration: textConfiguration
        )
        let visionConfiguration = ScriptComposerConfiguration(
            maxKeyframeCount: videoAnalyzerMaxFrames,
            generationConfig: generationConfig
        )
        let visionComposer = Qwen3VLScriptComposer(
            modelDirectoryRoot: modelStore.modelDirectoryRoot,
            configuration: visionConfiguration,
            textFallback: textComposer
        )

        return VideoAnalyzer(
            transcriber: SpeechAnalyzerTranscriber(locale: defaultVideoTranscriptionLocale),
            sampler: AVFoundationFrameSampler(),
            visionComposer: visionComposer,
            textComposer: textComposer,
            maxFrames: videoAnalyzerMaxFrames
        )
    }
}

private struct ClipRetrievalIndexer: ClipDigestIndexing {
    let chunker: any Chunker
    let embeddingEngine: any EmbeddingEngine
    let vectorStore: any VectorStore
    let keywordIndex: any KeywordIndex

    func index(_ payload: ClipDigestIndexingPayload) async throws -> ClipDigestIndexingResult {
        let chunks = chunker.chunk(
            clipID: payload.clipID,
            text: payload.bodyText,
            config: ChunkingConfig()
        )
        guard !chunks.isEmpty else {
            return ClipDigestIndexingResult(preview: nil)
        }

        let vectors = try await embeddingEngine.embed(chunks.map(\.text))
        guard vectors.count == chunks.count else {
            throw RetrievalError.invalidEmbeddingOutput(
                engineID: embeddingEngine.metadata.id,
                reason: "embedded \(vectors.count) vectors for \(chunks.count) chunks"
            )
        }

        try await vectorStore.upsert(Array(zip(chunks, vectors)).map { (chunk: $0.0, vector: $0.1) })
        try await keywordIndex.index(chunks)

        let preview = chunks
            .prefix(3)
            .enumerated()
            .map { index, chunk in
                let text = chunk.preview ?? chunk.text
                return "\(index + 1). \(text)"
            }
            .joined(separator: "\n")
        return ClipDigestIndexingResult(preview: preview.isEmpty ? nil : preview)
    }
}
