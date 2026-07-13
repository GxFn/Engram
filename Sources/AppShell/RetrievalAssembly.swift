import AnalysisStore
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
import ShotDetection
import SpeechTranscription
import SwiftData
import VectorStoreSQLite
import VideoUnderstanding

struct RetrievalServices: Sendable {
    let clipDigestService: ClipDigestService
    let retriever: any Retriever
}

enum RetrievalAssembly {
    static let defaultVideoTranscriptionLocale = Locale(identifier: "zh_CN")

    /// Leaf-only runtime seam used by production black-box tests. It deliberately cannot replace
    /// `VideoAnalyzing`: RetrievalAssembly still constructs the real orchestrator, artifact store,
    /// ClipDigest service, persistence and indexer.
    struct VideoPipelineRuntime: Sendable {
        let probe: any VideoAssetProbing
        let detector: any ShotBoundaryDetecting
        let keyframeSelector: any ShotKeyframeSelecting
        let transcriber: any Transcriber
        let corrector: (any TranscriptCorrecting)?
        let recognizer: any FrameTextRecognizing
        let understandingProvider: any ShotUnderstandingProviding
        let pipelineVersion: String
        let representativeFramesPerShot: Int
        let runID: @Sendable () -> String

        init(
            probe: any VideoAssetProbing,
            detector: any ShotBoundaryDetecting,
            keyframeSelector: any ShotKeyframeSelecting,
            transcriber: any Transcriber,
            corrector: (any TranscriptCorrecting)? = nil,
            recognizer: any FrameTextRecognizing,
            understandingProvider: any ShotUnderstandingProviding,
            pipelineVersion: String,
            representativeFramesPerShot: Int = 2,
            runID: @escaping @Sendable () -> String = { UUID().uuidString }
        ) {
            self.probe = probe
            self.detector = detector
            self.keyframeSelector = keyframeSelector
            self.transcriber = transcriber
            self.corrector = corrector
            self.recognizer = recognizer
            self.understandingProvider = understandingProvider
            self.pipelineVersion = pipelineVersion
            self.representativeFramesPerShot = min(3, max(1, representativeFramesPerShot))
            self.runID = runID
        }
    }

    @MainActor
    static func makeServices(
        modelContainer: ModelContainer,
        modelStore: ModelStore,
        activeEngine: any LLMEngine,
        activeModel: ModelIdentity,
        generationConfig: GenerationConfig,
        videoAnalyzer: (any VideoAnalyzing)? = nil,
        visionGenerator: (any VisionScriptGenerating)? = nil,
        cloudVideoConfiguration: CloudAIResolver.VideoConfiguration? = nil,
        appGroupLocations: AppGroupLocations? = nil,
        embeddingEngine: (any EmbeddingEngine)? = nil,
        videoPipelineRuntime: VideoPipelineRuntime? = nil
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
        let videoAnalyzer = try videoAnalyzer ?? makeVideoAnalyzer(
            modelStore: modelStore,
            activeEngine: activeEngine,
            activeModel: activeModel,
            generationConfig: generationConfig,
            visionGenerator: visionGenerator,
            cloudVideoConfiguration: cloudVideoConfiguration,
            artifactRoot: locations.rootDirectory.appendingPathComponent("analysis-artifacts", isDirectory: true),
            runtime: videoPipelineRuntime
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
        visionGenerator: (any VisionScriptGenerating)? = nil,
        cloudVideoConfiguration: CloudAIResolver.VideoConfiguration? = nil,
        artifactRoot: URL,
        runtime: VideoPipelineRuntime? = nil
    ) throws -> any VideoAnalyzing {
        if let runtime {
            return EvidenceGroundedVideoAnalyzer(
                probe: runtime.probe,
                detector: runtime.detector,
                keyframeSelector: runtime.keyframeSelector,
                transcriber: runtime.transcriber,
                corrector: runtime.corrector,
                recognizer: runtime.recognizer,
                understandingProvider: runtime.understandingProvider,
                cloudEnricher: cloudVideoConfiguration.map(ConfiguredCloudStoryboardEnricher.init),
                artifactStore: try AnalysisArtifactStore(rootURL: artifactRoot),
                pipelineVersion: runtime.pipelineVersion,
                representativeFramesPerShot: runtime.representativeFramesPerShot,
                runID: runtime.runID
            )
        }
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

        return EvidenceGroundedVideoAnalyzer(
            probe: AVFoundationVideoAssetProbe(),
            detector: AVFoundationShotBoundaryDetector(),
            keyframeSelector: AVFoundationShotKeyframeSelector(),
            transcriber: SpeechAnalyzerTranscriber(locale: defaultVideoTranscriptionLocale),
            corrector: LLMTranscriptCorrector(engine: activeEngine, model: activeModel),
            recognizer: VisionFrameTextRecognizer(),
            understandingProvider: VisionComposerShotUnderstandingProvider(
                composer: visionComposer,
                source: visionGenerator == nil ? .onDeviceModel : .cloudModel
            ),
            cloudEnricher: cloudVideoConfiguration.map(ConfiguredCloudStoryboardEnricher.init),
            artifactStore: try AnalysisArtifactStore(rootURL: artifactRoot),
            pipelineVersion: "storyboard-v2.1",
            representativeFramesPerShot: 2
        )
    }
}

struct ConfiguredCloudStoryboardEnricher: CloudStoryboardEnriching {
    let configuration: CloudAIResolver.VideoConfiguration
    private let capabilityProbe: any CloudCapabilityProbing
    private let clientFactory: @Sendable (CloudProviderProfile) -> any CloudVideoJobClient
    private let sleep: @Sendable (Duration) async throws -> Void

    init(_ configuration: CloudAIResolver.VideoConfiguration) {
        self.init(
            configuration: configuration,
            capabilityProbe: HTTPCloudCapabilityProbe(),
            clientFactory: { URLSessionCloudVideoJobClient(profile: $0) },
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    init(
        configuration: CloudAIResolver.VideoConfiguration,
        capabilityProbe: any CloudCapabilityProbing,
        clientFactory: @escaping @Sendable (CloudProviderProfile) -> any CloudVideoJobClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.configuration = configuration
        self.capabilityProbe = capabilityProbe
        self.clientFactory = clientFactory
        self.sleep = sleep
    }

    func enrich(
        source: VideoSource,
        asset: VideoAssetDescriptor,
        graph: ShotGraph,
        resume: CloudVideoJobCheckpoint?,
        checkpoint: @Sendable (CloudVideoJobCheckpoint) async throws -> Void
    ) async throws -> CloudStoryboardEnrichment {
        let rawProbe = await capabilityProbe.probe(configuration.profile)
        // A configured cloud VLM has already completed the per-shot frame-understanding stage by
        // the time this enhancer runs. Preserve the unauthenticated probe evidence while recording
        // that observed standard capability instead of incorrectly labelling the result local.
        let available = rawProbe.available.union([.frameUnderstanding])
        let probe = CloudCapabilityProbeResult(
            providerID: rawProbe.providerID,
            available: available,
            unavailable: configuration.profile.declaredCapabilities.subtracting(available),
            checkedAt: rawProbe.checkedAt,
            evidence: rawProbe.evidence + "; configured per-shot frame endpoint selected"
        )
        let decision = CloudModeResolver.resolve(
            requested: configuration.requestedMode,
            profile: configuration.profile,
            probe: probe,
            consent: configuration.consent
        )
        guard decision.effectiveMode == .cloudDeep, decision.mediaUploadAllowed else {
            return CloudStoryboardEnrichment(context: StoryboardExecutionContext(
                requestedCloudMode: decision.requestedMode,
                cloudMode: decision.effectiveMode,
                mediaUploaded: false,
                degradationNote: decision.degradationNote
            ))
        }
        var hasSubmittedJob = false
        var requestBytes: Int64?
        var activeJobID: String?
        let client = clientFactory(configuration.profile)
        do {
            var receipt: CloudVideoJobReceipt
            if let resume,
               resume.providerID == configuration.profile.id,
               resume.sourceFingerprint == asset.fingerprint.value {
                hasSubmittedJob = true
                activeJobID = resume.jobID
                receipt = try await client.status(jobID: resume.jobID, bearerToken: configuration.bearerToken)
            } else {
                guard await configuration.consumeUploadConsent() else {
                    return CloudStoryboardEnrichment(context: StoryboardExecutionContext(
                        requestedCloudMode: decision.requestedMode,
                        cloudMode: .cloudStandard,
                        mediaUploaded: false,
                        degradationNote: "full-video upload consent was already consumed; enable it again for this video"
                    ))
                }
                let media = try Data(contentsOf: source.localFileURL, options: .mappedIfSafe)
                let request = CloudVideoJobRequest(
                    sourceID: source.id,
                    sourceFingerprint: asset.fingerprint.value,
                    byteCount: Int64(media.count),
                    requestedCapabilities: [.fullVideo, .cloudASR]
                )
                requestBytes = try client.inlineRequestByteCount(request, media: media)
                receipt = try await client.submit(
                    request,
                    media: media,
                    consent: configuration.consent,
                    bearerToken: configuration.bearerToken
                )
                hasSubmittedJob = true
                activeJobID = receipt.jobID
                try await checkpoint(Self.checkpoint(receipt, configuration: configuration, asset: asset))
            }
            var polls = 0
            while receipt.state == .queued || receipt.state == .running {
                try Task.checkCancellation()
                guard polls < 60 else {
                    throw CloudVideoJobError.invalidResponse("cloud video job timed out")
                }
                try await sleep(.seconds(1))
                receipt = try await client.status(jobID: receipt.jobID, bearerToken: configuration.bearerToken)
                try await checkpoint(Self.checkpoint(receipt, configuration: configuration, asset: asset))
                polls += 1
            }
            guard receipt.state == .completed else {
                return CloudStoryboardEnrichment(context: StoryboardExecutionContext(
                    requestedCloudMode: decision.requestedMode,
                    cloudMode: .cloudStandard,
                    mediaUploaded: true,
                    mediaBytesUploaded: asset.fileSizeBytes,
                    requestBytes: requestBytes,
                    requestCount: receipt.usage.requestCount,
                    inputTokens: receipt.usage.inputTokens,
                    outputTokens: receipt.usage.outputTokens,
                    mediaMilliseconds: receipt.usage.mediaMilliseconds,
                    estimatedUSD: receipt.usage.estimatedUSD,
                    sanitizedError: receipt.sanitizedError,
                    degradationNote: "cloudDeep job \(receipt.state.rawValue) and degraded to cloudStandard: \(CloudErrorSanitizer.sanitize(receipt.sanitizedError ?? "provider returned no detail"))"
                ))
            }
            let alignment = CloudTimelineAligner.align(receipt.observations, to: graph)
            let refinement = CloudRefinementPlanner.plan(alignment)
            let summary = receipt.observations
                .filter { $0.kind == .visual }
                .map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return CloudStoryboardEnrichment(
                context: StoryboardExecutionContext(
                    requestedCloudMode: decision.requestedMode,
                    cloudMode: .cloudDeep,
                    mediaUploaded: true,
                    mediaBytesUploaded: asset.fileSizeBytes,
                    requestBytes: requestBytes,
                    requestCount: receipt.usage.requestCount,
                    inputTokens: receipt.usage.inputTokens,
                    outputTokens: receipt.usage.outputTokens,
                    mediaMilliseconds: receipt.usage.mediaMilliseconds,
                    estimatedUSD: receipt.usage.estimatedUSD,
                    refinementShotIDs: refinement.shotIDs
                ),
                evidence: alignment.items.map(\.evidence),
                shotsNeedingReview: refinement.shotIDs,
                globalSummary: summary.isEmpty ? nil : summary
            )
        } catch is CancellationError {
            if let activeJobID,
               configuration.profile.declaredCapabilities.contains(.jobCancellation),
               let receipt = try? await client.cancel(
                   jobID: activeJobID,
                   bearerToken: configuration.bearerToken
               ) {
                try? await checkpoint(Self.checkpoint(
                    receipt,
                    configuration: configuration,
                    asset: asset
                ))
            }
            throw CancellationError()
        } catch {
            let sanitized = CloudErrorSanitizer.sanitize(String(describing: error))
            if hasSubmittedJob {
                if let activeJobID {
                    try? await checkpoint(CloudVideoJobCheckpoint(
                        providerID: configuration.profile.id,
                        sourceFingerprint: asset.fingerprint.value,
                        jobID: activeJobID,
                        state: "transport-error",
                        sanitizedError: sanitized
                    ))
                }
                throw VideoUnderstandingError.visionUnavailable(
                    "cloud video job is checkpointed for resume: \(sanitized)"
                )
            }
            return CloudStoryboardEnrichment(context: StoryboardExecutionContext(
                requestedCloudMode: decision.requestedMode,
                cloudMode: .cloudStandard,
                mediaUploaded: false,
                sanitizedError: sanitized,
                degradationNote: "cloudDeep failed after probe and degraded to cloudStandard: \(sanitized)"
            ))
        }
    }

    private static func checkpoint(
        _ receipt: CloudVideoJobReceipt,
        configuration: CloudAIResolver.VideoConfiguration,
        asset: VideoAssetDescriptor
    ) -> CloudVideoJobCheckpoint {
        CloudVideoJobCheckpoint(
            providerID: configuration.profile.id,
            sourceFingerprint: asset.fingerprint.value,
            jobID: receipt.jobID,
            state: receipt.state.rawValue,
            sanitizedError: receipt.sanitizedError
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
