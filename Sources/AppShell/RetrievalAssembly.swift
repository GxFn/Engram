import AppGroupSupport
import ClipDigest
import CloudVision
import EmbeddingMLX
import EngineKit
import Foundation
import FrameVision
import ModelStore
import RAGCore
import ScriptComposer
import ScriptCore
import SpeechTranscription
import SwiftData
import VectorStoreSQLite

struct RetrievalServices: Sendable {
    let clipDigestService: ClipDigestService
    let retriever: any Retriever
}

enum RetrievalAssembly {
    static let defaultVideoTranscriptionLocale = Locale(identifier: "zh_CN")

    /// Base (floor) of the analyzer's duration-adaptive frame budget (~1 frame / 10s, ceiling 16).
    private static let videoAnalyzerMaxFrames = 6

    @MainActor
    static func makeServices(
        modelContainer: ModelContainer,
        modelStore: ModelStore,
        activeEngine: any LLMEngine,
        activeModel: ModelIdentity,
        generationConfig: GenerationConfig,
        videoAnalyzer: (any VideoAnalyzing)? = nil,
        visionGenerator: (any VisionScriptGenerating)? = nil,
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
            generationConfig: generationConfig,
            visionGenerator: visionGenerator
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
        generationConfig: GenerationConfig,
        visionGenerator: (any VisionScriptGenerating)? = nil
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
            // Accept up to the analyzer's ceiling: the analyzer scales frames with duration, and the
            // composer must not trim that adaptive budget back to the floor.
            maxKeyframeCount: 16,
            generationConfig: generationConfig
        )
        // A cloud generator (selected by the user) replaces the on-device MLX backend at this
        // one seam; everything downstream — composer, prompt, JSON decoding — is identical.
        let visionComposer: Qwen3VLScriptComposer
        if let visionGenerator {
            visionComposer = Qwen3VLScriptComposer(
                generator: visionGenerator,
                configuration: visionConfiguration,
                textFallback: textComposer
            )
        } else {
            visionComposer = Qwen3VLScriptComposer(
                modelDirectoryRoot: modelStore.modelDirectoryRoot,
                configuration: visionConfiguration,
                textFallback: textComposer
            )
        }

        return VideoAnalyzer(
            transcriber: SpeechAnalyzerTranscriber(locale: defaultVideoTranscriptionLocale),
            sampler: AVFoundationFrameSampler(),
            visionComposer: visionComposer,
            textComposer: textComposer,
            // Cleans the raw ASR with the active text engine before scripting (cheap, one call);
            // gracefully returns the raw transcript if the model/network is unavailable.
            corrector: LLMTranscriptCorrector(engine: activeEngine, model: activeModel),
            // Deterministic on-device OCR of burned-in 字幕/on-screen text — runs regardless of the
            // 云端/本地 vision backend, so captions are captured and attached to shots.
            recognizer: VisionFrameTextRecognizer(),
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

    func deleteClip(clipID: String) async throws {
        try await vectorStore.deleteClip(clipID: clipID)
        try await keywordIndex.deleteClip(clipID: clipID)
    }
}
