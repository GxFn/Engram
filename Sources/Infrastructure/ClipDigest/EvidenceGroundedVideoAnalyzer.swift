import AnalysisStore
import ClipCore
import Foundation
import ScriptCore
import StoryboardCore
import VideoUnderstanding

public struct EvidenceGroundedAnalysis: Sendable {
    public let document: StoryboardDocumentV2
    public let legacy: Script
    public let evidence: [EvidenceRef]
    public let quality: QualityReport
    public let run: AnalysisRun
}

public struct StoryboardExecutionContext: Codable, Hashable, Sendable {
    public let requestedCloudMode: EffectiveCloudMode
    public let cloudMode: EffectiveCloudMode
    public let mediaUploaded: Bool
    public let mediaBytesUploaded: Int64?
    public let requestBytes: Int64?
    public let requestCount: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let mediaMilliseconds: Int64?
    public let estimatedUSD: Decimal?
    public let sanitizedError: String?
    public let refinementShotIDs: [ShotID]
    public let degradationNote: String?
    public let analysisRequestedMode: String?
    public let analysisEffectiveMode: String?
    public let providerRoles: [String]
    public let cleanupState: String?

    public init(
        requestedCloudMode: EffectiveCloudMode? = nil,
        cloudMode: EffectiveCloudMode,
        mediaUploaded: Bool,
        mediaBytesUploaded: Int64? = nil,
        requestBytes: Int64? = nil,
        requestCount: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        mediaMilliseconds: Int64? = nil,
        estimatedUSD: Decimal? = nil,
        sanitizedError: String? = nil,
        refinementShotIDs: [ShotID] = [],
        degradationNote: String? = nil,
        analysisRequestedMode: String? = nil,
        analysisEffectiveMode: String? = nil,
        providerRoles: [String] = [],
        cleanupState: String? = nil
    ) {
        self.requestedCloudMode = requestedCloudMode ?? cloudMode
        self.cloudMode = cloudMode
        self.mediaUploaded = mediaUploaded
        self.mediaBytesUploaded = mediaBytesUploaded
        self.requestBytes = requestBytes
        self.requestCount = requestCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.mediaMilliseconds = mediaMilliseconds
        self.estimatedUSD = estimatedUSD
        self.sanitizedError = sanitizedError
        self.refinementShotIDs = refinementShotIDs
        self.degradationNote = degradationNote
        self.analysisRequestedMode = analysisRequestedMode
        self.analysisEffectiveMode = analysisEffectiveMode
        self.providerRoles = providerRoles
        self.cleanupState = cleanupState
    }

    public static let local = StoryboardExecutionContext(cloudMode: .local, mediaUploaded: false)

    private enum CodingKeys: String, CodingKey {
        case requestedCloudMode, cloudMode, mediaUploaded, mediaBytesUploaded, requestBytes
        case requestCount, inputTokens, outputTokens, mediaMilliseconds, estimatedUSD
        case sanitizedError, refinementShotIDs, degradationNote
        case analysisRequestedMode, analysisEffectiveMode, providerRoles, cleanupState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let effective = try container.decode(EffectiveCloudMode.self, forKey: .cloudMode)
        requestedCloudMode = try container.decodeIfPresent(EffectiveCloudMode.self, forKey: .requestedCloudMode) ?? effective
        cloudMode = effective
        mediaUploaded = try container.decode(Bool.self, forKey: .mediaUploaded)
        mediaBytesUploaded = try container.decodeIfPresent(Int64.self, forKey: .mediaBytesUploaded)
        requestBytes = try container.decodeIfPresent(Int64.self, forKey: .requestBytes)
        requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        mediaMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .mediaMilliseconds)
        estimatedUSD = try container.decodeIfPresent(Decimal.self, forKey: .estimatedUSD)
        sanitizedError = try container.decodeIfPresent(String.self, forKey: .sanitizedError)
        refinementShotIDs = try container.decodeIfPresent([ShotID].self, forKey: .refinementShotIDs) ?? []
        degradationNote = try container.decodeIfPresent(String.self, forKey: .degradationNote)
        analysisRequestedMode = try container.decodeIfPresent(String.self, forKey: .analysisRequestedMode)
        analysisEffectiveMode = try container.decodeIfPresent(String.self, forKey: .analysisEffectiveMode)
        providerRoles = try container.decodeIfPresent([String].self, forKey: .providerRoles) ?? []
        cleanupState = try container.decodeIfPresent(String.self, forKey: .cleanupState)
    }

    var telemetry: AnalysisCloudTelemetry {
        AnalysisCloudTelemetry(
            requestedMode: analysisRequestedMode ?? requestedCloudMode.rawValue,
            effectiveMode: analysisEffectiveMode ?? cloudMode.rawValue,
            mediaBytesUploaded: mediaBytesUploaded,
            requestBytes: requestBytes,
            requestCount: requestCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            mediaMilliseconds: mediaMilliseconds,
            estimatedUSD: estimatedUSD,
            sanitizedError: sanitizedError,
            refinementShotIDs: refinementShotIDs.map(\.rawValue),
            providerRoles: providerRoles.isEmpty ? nil : providerRoles,
            cleanupState: cleanupState
        )
    }
}

public struct ShotUnderstandingInput: Sendable {
    public let shot: ShotSegment
    public let keyframes: [ShotKeyframe]
    public let evidence: [EvidenceRef]
    public let transcript: [TranscriptSegment]
    public let onScreenText: [FrameText]
}

public struct ShotUnderstandingOutput: Codable, Hashable, Sendable {
    public let shot: StoryboardShotV2
    public let title: String?
    public let summary: String?
    public let themes: [String]
    public let hook: String?
    public let retentionDevices: [String]
    public let payoff: String?
    public let callToAction: String?
    public let degradationNote: String?

    public init(
        shot: StoryboardShotV2,
        title: String? = nil,
        summary: String? = nil,
        themes: [String] = [],
        hook: String? = nil,
        retentionDevices: [String] = [],
        payoff: String? = nil,
        callToAction: String? = nil,
        degradationNote: String? = nil
    ) {
        self.shot = shot
        self.title = title
        self.summary = summary
        self.themes = themes
        self.hook = hook
        self.retentionDevices = retentionDevices
        self.payoff = payoff
        self.callToAction = callToAction
        self.degradationNote = degradationNote
    }
}

public protocol ShotUnderstandingProviding: Sendable {
    func understand(_ input: ShotUnderstandingInput, displayNumber: Int) async throws -> ShotUnderstandingOutput
}

/// Compatibility at the model seam only: the established VLM composer is invoked once per
/// authoritative shot. Its text never creates boundaries and every observed field is linked to
/// the shot's real frame/ASR/OCR evidence before it enters V2.
public struct VisionComposerShotUnderstandingProvider: ShotUnderstandingProviding {
    private let composer: any VisionScriptComposing
    private let source: EvidenceSource

    public init(composer: any VisionScriptComposing, source: EvidenceSource = .onDeviceModel) {
        self.composer = composer
        self.source = source
    }

    public func understand(_ input: ShotUnderstandingInput, displayNumber: Int) async throws -> ShotUnderstandingOutput {
        let script = try await composer.compose(
            sourceID: input.shot.id.rawValue,
            transcript: input.transcript,
            keyframes: input.keyframes.map(\.frame),
            onScreenText: input.onScreenText
        )
        let modelShot = script.shots.max { lhs, rhs in
            Self.overlap(lhs, input.shot) < Self.overlap(rhs, input.shot)
        }
        let visualEvidence = input.evidence.filter { $0.kind == .frame || $0.kind == .ocr }.map(\.id)
        let textEvidence = input.evidence.filter { $0.kind == .ocr }.map(\.id)
        let speechEvidence = input.evidence.filter { $0.kind == .transcript || $0.kind == .audio }.map(\.id)
        var facts: [GroundedFact] = []
        if let value = Self.normalized(modelShot?.visualDescription), !visualEvidence.isEmpty {
            facts.append(GroundedFact(
                field: .action,
                value: value,
                evidenceIDs: visualEvidence,
                source: source,
                confidence: 0.7
            ))
        }
        if let value = Self.normalized(modelShot?.narration), !speechEvidence.isEmpty {
            facts.append(GroundedFact(
                field: .audioSummary,
                value: value,
                evidenceIDs: speechEvidence,
                source: source,
                confidence: 0.8
            ))
        }
        for value in modelShot?.onScreenText ?? [] where !textEvidence.isEmpty {
            facts.append(GroundedFact(
                field: .visibleText,
                value: value,
                evidenceIDs: textEvidence,
                source: source,
                confidence: 0.8
            ))
        }
        let plan = ShotProductionPlan(
            shotID: input.shot.id,
            displayNumber: displayNumber,
            purpose: Self.normalized(modelShot?.pacingNote),
            subjectAction: Self.normalized(modelShot?.visualDescription),
            dialogueOrVO: Self.normalized(modelShot?.narration),
            onScreenCopy: modelShot?.onScreenText.joined(separator: " / ").nilIfEmpty,
            sourceShotRefs: [input.shot.id],
            confidence: facts.map(\.confidence).min(),
            isDerivedCreativePlan: true
        )
        return ShotUnderstandingOutput(
            shot: StoryboardShotV2(
                id: input.shot.id,
                observedFacts: ObservedShotFacts(
                    facts: facts,
                    unknownFields: facts.isEmpty ? [.action, .audioSummary] : [],
                    modelConfidence: facts.map(\.confidence).min(),
                    reviewFlags: facts.isEmpty ? ["no-grounded-model-facts"] : []
                ),
                productionPlan: plan
            ),
            title: script.title.nilIfEmpty,
            summary: script.summary.nilIfEmpty,
            themes: script.visualElements,
            hook: script.hookStructure?.openingHook.nilIfEmpty,
            retentionDevices: script.hookStructure?.retentionDevices ?? [],
            payoff: script.hookStructure?.payoff,
            callToAction: script.hookStructure?.callToAction,
            degradationNote: script.degradationNote
        )
    }

    private static func overlap(_ shot: StoryboardShot, _ segment: ShotSegment) -> Double {
        max(0, min(shot.endSeconds, segment.timeRange.endSeconds) - max(shot.startSeconds, segment.timeRange.startSeconds))
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct CloudStoryboardEnrichment: Codable, Hashable, Sendable {
    public let context: StoryboardExecutionContext
    public let evidence: [EvidenceRef]
    public let productionPlans: [ShotProductionPlan]
    public let shotsNeedingReview: [ShotID]
    public let globalSummary: String?

    public init(
        context: StoryboardExecutionContext,
        evidence: [EvidenceRef] = [],
        productionPlans: [ShotProductionPlan] = [],
        shotsNeedingReview: [ShotID] = [],
        globalSummary: String? = nil
    ) {
        self.context = context
        self.evidence = evidence
        self.productionPlans = productionPlans
        self.shotsNeedingReview = shotsNeedingReview
        self.globalSummary = globalSummary
    }

    public static let local = CloudStoryboardEnrichment(context: .local)
}

public protocol CloudStoryboardEnriching: Sendable {
    func enrich(
        source: VideoSource,
        asset: VideoAssetDescriptor,
        graph: ShotGraph,
        resume: CloudVideoJobCheckpoint?,
        checkpoint: @Sendable (CloudVideoJobCheckpoint) async throws -> Void
    ) async throws -> CloudStoryboardEnrichment
}

public struct CloudVideoJobCheckpoint: Codable, Hashable, Sendable {
    public let providerID: String
    public let sourceFingerprint: String
    public let jobID: String
    public let state: String
    public let sanitizedError: String?
    /// Provider-specific non-secret restart state. AppShell owns its schema; ClipDigest only stores
    /// it atomically beside the analysis run.
    public let opaqueState: Data?

    public init(
        providerID: String,
        sourceFingerprint: String,
        jobID: String,
        state: String,
        sanitizedError: String? = nil,
        opaqueState: Data? = nil
    ) {
        self.providerID = providerID
        self.sourceFingerprint = sourceFingerprint
        self.jobID = jobID
        self.state = state
        self.sanitizedError = sanitizedError
        self.opaqueState = opaqueState
    }
}

public protocol EvidenceGroundedVideoAnalyzing: VideoAnalyzing {
    func analyzeGrounded(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> EvidenceGroundedAnalysis
    func reanalyzeGrounded(
        _ source: VideoSource,
        document: StoryboardDocumentV2,
        shotIDs: [ShotID]
    ) async throws -> StoryboardDocumentV2
}

public extension EvidenceGroundedVideoAnalyzing {
    func analyze(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> Script {
        try await analyzeGrounded(source, onStage: onStage).legacy
    }
}

/// The production V2 orchestrator. It owns every stage from authoritative media probing through
/// final indexing checkpoint; the legacy Script exists only as the deterministic final projection.
public struct EvidenceGroundedVideoAnalyzer: EvidenceGroundedVideoAnalyzing {
    private let probe: any VideoAssetProbing
    private let detector: any ShotBoundaryDetecting
    private let keyframeSelector: any ShotKeyframeSelecting
    private let transcriber: any Transcriber
    private let corrector: (any TranscriptCorrecting)?
    private let recognizer: any FrameTextRecognizing
    private let understandingProvider: any ShotUnderstandingProviding
    private let refinementUnderstandingProvider: (any ShotUnderstandingProviding)?
    private let cloudEnricher: (any CloudStoryboardEnriching)?
    private let artifactStore: AnalysisArtifactStore
    private let pipelineVersion: String
    private let quality: AnalysisQuality
    private let representativeFramesPerShot: Int
    private let makeRunID: @Sendable () -> String

    public init(
        probe: any VideoAssetProbing,
        detector: any ShotBoundaryDetecting,
        keyframeSelector: any ShotKeyframeSelecting,
        transcriber: any Transcriber,
        corrector: (any TranscriptCorrecting)? = nil,
        recognizer: any FrameTextRecognizing,
        understandingProvider: any ShotUnderstandingProviding,
        refinementUnderstandingProvider: (any ShotUnderstandingProviding)? = nil,
        cloudEnricher: (any CloudStoryboardEnriching)? = nil,
        artifactStore: AnalysisArtifactStore,
        pipelineVersion: String = "storyboard-v2.1",
        quality: AnalysisQuality = .balanced,
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
        self.refinementUnderstandingProvider = refinementUnderstandingProvider
        self.cloudEnricher = cloudEnricher
        self.artifactStore = artifactStore
        self.pipelineVersion = pipelineVersion
        self.quality = quality
        self.representativeFramesPerShot = min(3, max(1, representativeFramesPerShot))
        self.makeRunID = runID
    }

    public func analyzeGrounded(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> EvidenceGroundedAnalysis {
        let asset = try await probe.probe(source)
        let resumable = try await artifactStore.loadResumableRun(
            clipID: source.id,
            fingerprint: asset.fingerprint,
            pipelineVersion: pipelineVersion
        )
        var run: AnalysisRun
        if let resumable {
            run = resumable
        } else {
            run = try await artifactStore.createRun(
                clipID: source.id,
                fingerprint: asset.fingerprint,
                pipelineVersion: pipelineVersion,
                runID: makeRunID()
            )
        }

        (run, _) = try await checkpoint(asset, stage: .assetProbe, run: run)
        var graph: ShotGraph
        (run, graph) = try await stage(.shotDetection, run: run) {
            try await detector.detect(in: asset, sourceURL: source.localFileURL, quality: quality)
        }
        let keyframes: [ShotKeyframe]
        let keyframeRun = run
        (run, keyframes) = try await stage(.keyframes, run: run) {
            try await shotKeyframes(
                graph: graph,
                sourceURL: source.localFileURL,
                shotIDs: Set(graph.shots.map(\.id)),
                run: keyframeRun
            )
        }
        graph = try Self.attachingKeyframeReferences(keyframes, to: graph)

        await onStage(.transcribing)
        let transcription: TranscriptionArtifact
        (run, transcription) = try await stage(.transcription, run: run) {
            do {
                return TranscriptionArtifact(raw: try await transcriber.transcribe(source), degradationNote: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return TranscriptionArtifact(raw: [], degradationNote: "transcription unavailable: \(error)")
            }
        }
        let ocr: [FrameText]
        (run, ocr) = try await stage(.ocr, run: run) {
            await recognizer.recognizeText(in: source)
        }
        let corrected = try await correctedTranscript(transcription.raw, ocr: ocr)
        let localEvidence: [EvidenceRef]
        let evidenceRun = run
        (run, localEvidence) = try await stage(.evidenceAssembly, run: run) {
            try await shotEvidence(
                asset: asset,
                graph: graph,
                keyframes: keyframes,
                raw: transcription.raw,
                corrected: corrected,
                ocr: ocr,
                shotIDs: Set(graph.shots.map(\.id)),
                run: evidenceRun
            )
        }
        await onStage(.scripting)
        if let stored: [ShotUnderstandingOutput] = try await artifactStore.loadArtifact(
            [ShotUnderstandingOutput].self,
            stage: .shotUnderstanding,
            from: run
        ), stored.contains(where: Self.isFailedUnderstanding) {
            run = try await artifactStore.invalidate(
                stages: Set(AnalysisStage.allCases.drop {
                    $0 != .shotUnderstanding
                }),
                from: run
            )
        }
        var understandings: [ShotUnderstandingOutput]
        (run, understandings) = try await stage(.shotUnderstanding, run: run) {
            try await understand(
                graph: graph,
                keyframes: keyframes,
                evidence: localEvidence,
                corrected: corrected,
                ocr: ocr,
                run: run
            )
        }
        let cloud: CloudStoryboardEnrichment
        let cloudResume: CloudVideoJobCheckpoint? = try await artifactStore.loadAuxiliaryArtifact(
            CloudVideoJobCheckpoint.self,
            name: "cloud-job",
            from: run
        )
        let cloudRun = run
        (run, cloud) = try await stage(.cloudVideo, run: run) {
            guard let cloudEnricher else { return .local }
            return try await cloudEnricher.enrich(
                source: source,
                asset: asset,
                graph: graph,
                resume: cloudResume,
                checkpoint: { value in
                    try await artifactStore.saveAuxiliaryArtifact(value, name: "cloud-job", for: cloudRun)
                }
            )
        }
        run = try await artifactStore.recordCloudTelemetry(cloud.context.telemetry, for: run)
        try await artifactStore.deleteAuxiliaryArtifact(name: "cloud-job", from: run)
        let evidence = (localEvidence + cloud.evidence).sorted { $0.id < $1.id }
        let refinementIDs = Set(cloud.context.refinementShotIDs)
        if !refinementIDs.isEmpty {
            let refined = try await understand(
                graph: graph,
                keyframes: keyframes,
                evidence: evidence,
                corrected: corrected,
                ocr: ocr,
                selectedShotIDs: refinementIDs,
                run: run,
                provider: refinementUnderstandingProvider ?? understandingProvider,
                cacheNamespace: "cloud-selected-refinement"
            )
            let replacements = Dictionary(uniqueKeysWithValues: refined.map { ($0.shot.id, $0) })
            understandings = understandings.map { replacements[$0.shot.id] ?? $0 }
        }
        let finalAssembly: ShotEvidenceAssemblyResult
        (run, finalAssembly) = try await stage(.timelineAlignment, run: run) {
            ShotEvidenceAssembler.assemble(graph: graph, evidence: evidence)
        }
        let document: StoryboardDocumentV2
        (run, document) = try await stage(.synthesis, run: run) {
            Self.synthesize(
                source: source,
                run: run,
                pipelineVersion: pipelineVersion,
                graph: graph,
                understandings: understandings,
                cloud: cloud,
                transcription: transcription,
                finalAssembly: finalAssembly
            )
        }
        let report: QualityReport
        (run, report) = try await stage(.quality, run: run) {
            Self.qualityReport(
                StoryboardValidator.validate(document: document, evidence: evidence),
                document: document,
                transcription: transcription,
                assembly: finalAssembly,
                cloud: cloud
            )
        }
        let legacy = StoryboardLegacyProjector.project(document, createdAt: source.importedAt)
        let indexing = IndexingArtifact(legacy: legacy, documentID: document.id, qualityStatus: report.status)
        (run, _) = try await checkpoint(indexing, stage: .indexing, run: run)
        (run, _) = try await checkpoint(CompletionArtifact(completed: true), stage: .completed, run: run)

        guard run.status == .completed else {
            throw VideoUnderstandingError.unreadableAsset("storyboard run did not reach completed checkpoint")
        }
        return EvidenceGroundedAnalysis(document: document, legacy: legacy, evidence: evidence, quality: report, run: run)
    }

    public func reanalyzeGrounded(
        _ source: VideoSource,
        document: StoryboardDocumentV2,
        shotIDs: [ShotID]
    ) async throws -> StoryboardDocumentV2 {
        let selected = Set(shotIDs)
        guard !selected.isEmpty else { return document }
        let asset = try await probe.probe(source)
        let resumable = try await artifactStore.loadResumableRun(
            clipID: source.id,
            fingerprint: asset.fingerprint,
            pipelineVersion: pipelineVersion
        )
        let transcription: TranscriptionArtifact
        let ocr: [FrameText]
        if let resumable,
           let storedTranscription: TranscriptionArtifact = try await artifactStore.loadArtifact(
               TranscriptionArtifact.self, stage: .transcription, from: resumable
           ),
           let storedOCR: [FrameText] = try await artifactStore.loadArtifact(
               [FrameText].self, stage: .ocr, from: resumable
           ) {
            transcription = storedTranscription
            ocr = storedOCR
        } else {
            transcription = TranscriptionArtifact(raw: try await transcriber.transcribe(source), degradationNote: nil)
            ocr = await recognizer.recognizeText(in: source)
        }
        let corrected = try await correctedTranscript(transcription.raw, ocr: ocr)
        if let resumable {
            try await artifactStore.invalidateShotArtifacts(
                stages: [.keyframes, .evidenceAssembly, .shotUnderstanding, .synthesis, .quality, .indexing],
                shotIDs: selected,
                from: resumable
            )
        }
        let keyframes = try await shotKeyframes(
            graph: document.shotGraph,
            sourceURL: source.localFileURL,
            shotIDs: selected,
            run: resumable
        )
        let evidence = try await shotEvidence(
            asset: asset,
            graph: document.shotGraph,
            keyframes: keyframes,
            raw: transcription.raw,
            corrected: corrected,
            ocr: ocr,
            shotIDs: selected,
            run: resumable
        )
        let refreshed = try await understand(
            graph: document.shotGraph,
            keyframes: keyframes,
            evidence: evidence,
            corrected: corrected,
            ocr: ocr,
            selectedShotIDs: selected,
            run: resumable
        )

        var updated = document
        for output in refreshed {
            guard let existingIndex = updated.shots.firstIndex(where: { $0.id == output.shot.id }) else { continue }
            if updated.shots[existingIndex].productionPlan == nil {
                var shots = updated.shots
                let durableFacts = shots[existingIndex].observedFacts.facts.filter {
                    $0.source == .user || $0.source == .cloudModel
                }
                shots[existingIndex] = StoryboardShotV2(
                    id: output.shot.id,
                    observedFacts: Self.mergingDurableFacts(output.shot.observedFacts, durableFacts: durableFacts),
                    productionPlan: output.shot.productionPlan,
                    userLockedFields: updated.shots[existingIndex].userLockedFields
                )
                updated = StoryboardDocumentV2(
                    id: updated.id,
                    source: updated.source,
                    shotGraph: updated.shotGraph,
                    shots: shots,
                    contentAnalysis: updated.contentAnalysis
                )
                continue
            }
            let plan = output.shot.productionPlan
            var refreshedValues: [EditablePlanField: String?] = [:]
            if let value = plan?.purpose { refreshedValues[.purpose] = value }
            if let value = plan?.subjectAction { refreshedValues[.subjectAction] = value }
            if let value = plan?.dialogueOrVO { refreshedValues[.dialogueOrVO] = value }
            if let value = plan?.onScreenCopy { refreshedValues[.onScreenCopy] = value }
            if let value = plan?.productionNotes { refreshedValues[.productionNotes] = value }
            let edit = try StoryboardEditor.applyModelRefresh(
                updated,
                shotID: output.shot.id,
                values: refreshedValues
            )
            var shots = edit.document.shots
            guard let index = shots.firstIndex(where: { $0.id == output.shot.id }) else { continue }
            let current = shots[index]
            let durableFacts = current.observedFacts.facts.filter {
                $0.source == .user || $0.source == .cloudModel
            }
            shots[index] = StoryboardShotV2(
                id: current.id,
                observedFacts: Self.mergingDurableFacts(output.shot.observedFacts, durableFacts: durableFacts),
                productionPlan: current.productionPlan,
                userLockedFields: current.userLockedFields
            )
            updated = StoryboardDocumentV2(
                id: edit.document.id,
                source: edit.document.source,
                shotGraph: edit.document.shotGraph,
                shots: shots,
                contentAnalysis: edit.document.contentAnalysis
            )
        }
        return updated
    }

    private func correctedTranscript(_ raw: [TranscriptSegment], ocr: [FrameText]) async throws -> [TranscriptSegment] {
        guard let corrector else { return raw }
        do {
            return try await corrector.correct(raw, onScreenText: ocr)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return raw
        }
    }

    private func shotKeyframes(
        graph: ShotGraph,
        sourceURL: URL,
        shotIDs: Set<ShotID>,
        run: AnalysisRun?
    ) async throws -> [ShotKeyframe] {
        var result: [ShotKeyframe] = []
        for shot in graph.shots where shotIDs.contains(shot.id) {
            let cacheKey = try Self.cacheKey(ShotKeyframeCacheIdentity(
                pipelineVersion: pipelineVersion,
                shot: shot,
                framesPerShot: representativeFramesPerShot
            ))
            if let run,
               let cached: [ShotKeyframe] = try await artifactStore.loadShotArtifact(
                   [ShotKeyframe].self,
                   stage: .keyframes,
                   shotID: shot.id,
                   cacheKey: cacheKey,
                   from: run
               ) {
                result.append(contentsOf: cached)
                continue
            }
            let selected = try await keyframeSelector.select(
                in: graph,
                sourceURL: sourceURL,
                shotIDs: [shot.id],
                framesPerShot: representativeFramesPerShot
            ).filter { $0.shotID == shot.id }
            let bounded = Array(selected.sorted { $0.frame.timestampSeconds < $1.frame.timestampSeconds }.prefix(3))
            guard !bounded.isEmpty else {
                throw VideoUnderstandingError.unreadableAsset("no representative frame for \(shot.id.rawValue)")
            }
            if let run {
                try await artifactStore.saveShotArtifact(
                    bounded,
                    stage: .keyframes,
                    shotID: shot.id,
                    cacheKey: cacheKey,
                    for: run
                )
            }
            result.append(contentsOf: bounded)
        }
        return result
    }

    private func shotEvidence(
        asset: VideoAssetDescriptor,
        graph: ShotGraph,
        keyframes: [ShotKeyframe],
        raw: [TranscriptSegment],
        corrected: [TranscriptSegment],
        ocr: [FrameText],
        shotIDs: Set<ShotID>,
        run: AnalysisRun?
    ) async throws -> [EvidenceRef] {
        var result: [EvidenceRef] = []
        for shot in graph.shots where shotIDs.contains(shot.id) {
            let shotKeyframes = keyframes.filter { $0.shotID == shot.id }
            let cacheKey = try Self.cacheKey(ShotEvidenceCacheIdentity(
                pipelineVersion: pipelineVersion,
                shot: shot,
                keyframes: shotKeyframes,
                raw: raw.filter { Self.overlaps($0.startSeconds, $0.endSeconds, shot.timeRange) },
                corrected: corrected.filter { Self.overlaps($0.startSeconds, $0.endSeconds, shot.timeRange) },
                ocr: ocr.filter { shot.timeRange.contains($0.timestampSeconds) }
            ))
            if let run,
               let cached: [EvidenceRef] = try await artifactStore.loadShotArtifact(
                   [EvidenceRef].self,
                   stage: .evidenceAssembly,
                   shotID: shot.id,
                   cacheKey: cacheKey,
                   from: run
               ) {
                result.append(contentsOf: cached)
                continue
            }
            let assembled = Self.makeLocalEvidence(
                asset: asset,
                graph: graph,
                keyframes: shotKeyframes,
                raw: raw,
                corrected: corrected,
                ocr: ocr,
                selectedShotIDs: [shot.id]
            )
            if let run {
                try await artifactStore.saveShotArtifact(
                    assembled,
                    stage: .evidenceAssembly,
                    shotID: shot.id,
                    cacheKey: cacheKey,
                    for: run
                )
            }
            result.append(contentsOf: assembled)
        }
        return Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .sorted { $0.id < $1.id }
    }

    private func understand(
        graph: ShotGraph,
        keyframes: [ShotKeyframe],
        evidence: [EvidenceRef],
        corrected: [TranscriptSegment],
        ocr: [FrameText],
        selectedShotIDs: Set<ShotID>? = nil,
        run: AnalysisRun? = nil,
        provider: (any ShotUnderstandingProviding)? = nil,
        cacheNamespace: String = "baseline"
    ) async throws -> [ShotUnderstandingOutput] {
        var outputs: [ShotUnderstandingOutput] = []
        for (index, shot) in graph.shots.enumerated()
        where selectedShotIDs?.contains(shot.id) ?? true {
            let shotEvidence = evidence.filter { Self.overlaps($0.timeRange, shot.timeRange) }
            let input = ShotUnderstandingInput(
                shot: shot,
                keyframes: keyframes.filter { $0.shotID == shot.id },
                evidence: shotEvidence,
                transcript: corrected.filter { Self.overlaps($0.startSeconds, $0.endSeconds, shot.timeRange) },
                onScreenText: ocr.filter { shot.timeRange.contains($0.timestampSeconds) }
            )
            let cacheKey = Self.shotUnderstandingCacheKey(
                pipelineVersion: pipelineVersion,
                input: input,
                displayNumber: index + 1
            ) + "|\(cacheNamespace)"
            if let run,
               let cached: ShotUnderstandingOutput = try await artifactStore.loadShotArtifact(
                   ShotUnderstandingOutput.self,
                   stage: .shotUnderstanding,
                   shotID: shot.id,
                   cacheKey: cacheKey,
                   from: run
               ) {
                outputs.append(cached)
                continue
            }

            var finalError: Error?
            for _ in 0..<2 {
                do {
                    let output = try await (provider ?? understandingProvider)
                        .understand(input, displayNumber: index + 1)
                    guard output.shot.id == shot.id else {
                        throw VideoUnderstandingError.visionUnavailable("shot understanding returned mismatched ShotID")
                    }
                    if let run {
                        try await artifactStore.saveShotArtifact(
                            output,
                            stage: .shotUnderstanding,
                            shotID: shot.id,
                            cacheKey: cacheKey,
                            for: run
                        )
                    }
                    outputs.append(output)
                    finalError = nil
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    finalError = error
                }
            }
            if let finalError {
                outputs.append(ShotUnderstandingOutput(
                    shot: StoryboardShotV2(
                        id: shot.id,
                        observedFacts: ObservedShotFacts(
                            facts: [],
                            unknownFields: FactField.allCasesForReview,
                            reviewFlags: ["shot-understanding-failed: \(type(of: finalError))"]
                        ),
                        productionPlan: nil
                    )
                ))
            }
        }
        return outputs
    }

    private func checkpoint<T: Codable & Sendable>(
        _ value: T,
        stage: AnalysisStage,
        run: AnalysisRun
    ) async throws -> (AnalysisRun, T) {
        if let existing: T = try await artifactStore.loadArtifact(T.self, stage: stage, from: run) {
            return (run, existing)
        }
        let updated = try await artifactStore.commit(stage: stage, artifact: try Self.encoder().encode(value), for: run)
        return (updated, value)
    }

    private func stage<T: Codable & Sendable>(
        _ stage: AnalysisStage,
        run: AnalysisRun,
        operation: () async throws -> T
    ) async throws -> (AnalysisRun, T) {
        if let existing: T = try await artifactStore.loadArtifact(T.self, stage: stage, from: run) {
            return (run, existing)
        }
        let value = try await operation()
        return try await checkpoint(value, stage: stage, run: run)
    }

    private static func makeLocalEvidence(
        asset: VideoAssetDescriptor,
        graph: ShotGraph,
        keyframes: [ShotKeyframe],
        raw: [TranscriptSegment],
        corrected: [TranscriptSegment],
        ocr: [FrameText],
        selectedShotIDs: Set<ShotID>? = nil
    ) -> [EvidenceRef] {
        var result: [EvidenceRef] = []
        let selectedShots = graph.shots.filter { selectedShotIDs?.contains($0.id) ?? true }
        for shot in selectedShots {
            result.append(EvidenceRef(
                id: EvidenceID(rawValue: "detector:\(shot.id.rawValue)"),
                kind: .detector,
                timeRange: shot.timeRange,
                frameRange: shot.frameRange,
                payloadRef: "shots/\(shot.id.rawValue)/boundary.json",
                source: .deterministic,
                confidence: shot.boundaryConfidence
            ))
        }
        let selectedRanges = selectedShots.map(\.timeRange)
        for (keyframeIndex, keyframe) in keyframes.enumerated() {
            guard let shot = graph.shots.first(where: { $0.id == keyframe.shotID }) else { continue }
            result.append(EvidenceRef(
                id: EvidenceID(rawValue: "frame:\(keyframe.shotID.rawValue):\(keyframeIndex)"),
                kind: .frame,
                timeRange: Self.pointRange(keyframe.frame.timestampSeconds, duration: asset.durationSeconds),
                frameRange: FrameRange(
                    startFrame: max(shot.frameRange.startFrame, Int((keyframe.frame.timestampSeconds * asset.nominalFrameRate).rounded(.down))),
                    endFrameExclusive: min(shot.frameRange.endFrameExclusive, max(shot.frameRange.startFrame + 1, Int((keyframe.frame.timestampSeconds * asset.nominalFrameRate).rounded(.down)) + 1))
                ),
                payloadRef: keyframe.artifactRef,
                source: .deterministic,
                confidence: 1
            ))
        }
        for (index, segment) in raw.enumerated()
        where selectedRanges.contains(where: { Self.overlaps(segment.startSeconds, segment.endSeconds, $0) }) {
            let fixed = corrected.indices.contains(index) ? corrected[index] : segment
            result.append(EvidenceRef(
                id: EvidenceID(rawValue: "transcript:\(index)"),
                kind: .transcript,
                timeRange: Self.clampedRange(segment.startSeconds, segment.endSeconds, duration: asset.durationSeconds),
                frameRange: nil,
                payloadRef: "transcript/\(index).json",
                source: .deterministic,
                confidence: 0.9,
                rawText: segment.text,
                correctedText: fixed.text == segment.text ? nil : fixed.text
            ))
        }
        for (frameIndex, text) in ocr.enumerated()
        where selectedRanges.contains(where: { $0.contains(text.timestampSeconds) }) {
            for (lineIndex, line) in text.lines.enumerated() where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(EvidenceRef(
                    id: EvidenceID(rawValue: "ocr:\(frameIndex):\(lineIndex)"),
                    kind: .ocr,
                    timeRange: Self.pointRange(text.timestampSeconds, duration: asset.durationSeconds),
                    frameRange: nil,
                    payloadRef: "ocr/\(frameIndex)-\(lineIndex).json",
                    source: .deterministic,
                    confidence: 0.9,
                    rawText: line
                ))
            }
        }
        return result
    }

    private static func attachingKeyframeReferences(
        _ keyframes: [ShotKeyframe],
        to graph: ShotGraph
    ) throws -> ShotGraph {
        let refs = Dictionary(grouping: keyframes, by: \.shotID).mapValues { frames in
            frames.sorted { $0.frame.timestampSeconds < $1.frame.timestampSeconds }.map(\.artifactRef)
        }
        let shots = graph.shots.map { shot -> ShotSegment in
            let selected = refs[shot.id] ?? shot.representativeFrameRefs
            return ShotSegment(
                id: shot.id,
                timeRange: shot.timeRange,
                frameRange: shot.frameRange,
                transitionIn: shot.transitionIn,
                transitionOut: shot.transitionOut,
                boundaryConfidence: shot.boundaryConfidence,
                detectorEvidenceIDs: shot.detectorEvidenceIDs,
                representativeFrameRefs: selected
            )
        }
        return try ShotGraph(asset: graph.asset, shots: shots)
    }

    private static func mergingDurableFacts(
        _ modelFacts: ObservedShotFacts,
        durableFacts: [GroundedFact]
    ) -> ObservedShotFacts {
        var seen = Set<GroundedFact>()
        let merged = (modelFacts.facts.filter { $0.source != .user && $0.source != .cloudModel }
            + durableFacts).filter { seen.insert($0).inserted }
        return ObservedShotFacts(
            facts: merged,
            unknownFields: modelFacts.unknownFields,
            modelConfidence: modelFacts.modelConfidence,
            reviewFlags: modelFacts.reviewFlags
        )
    }

    private static func isFailedUnderstanding(_ output: ShotUnderstandingOutput) -> Bool {
        output.shot.observedFacts.reviewFlags.contains { $0.hasPrefix("shot-understanding-failed") }
    }

    private static func shotUnderstandingCacheKey(
        pipelineVersion: String,
        input: ShotUnderstandingInput,
        displayNumber: Int
    ) -> String {
        let identity = ShotUnderstandingCacheIdentity(
            pipelineVersion: pipelineVersion,
            shot: input.shot,
            displayNumber: displayNumber,
            keyframes: input.keyframes,
            evidence: input.evidence,
            transcript: input.transcript,
            onScreenText: input.onScreenText
        )
        return (try? encoder().encode(identity).base64EncodedString()) ?? "invalid-cache-identity"
    }

    private static func cacheKey<T: Encodable>(_ identity: T) throws -> String {
        try encoder().encode(identity).base64EncodedString()
    }

    private static func synthesize(
        source: VideoSource,
        run: AnalysisRun,
        pipelineVersion: String,
        graph: ShotGraph,
        understandings: [ShotUnderstandingOutput],
        cloud: CloudStoryboardEnrichment,
        transcription: TranscriptionArtifact,
        finalAssembly: ShotEvidenceAssemblyResult
    ) -> StoryboardDocumentV2 {
        let review = Set(cloud.shotsNeedingReview)
        let byID = Dictionary(uniqueKeysWithValues: understandings.map { ($0.shot.id, $0) })
        let cloudPlans = Dictionary(uniqueKeysWithValues: cloud.productionPlans.map { ($0.shotID, $0) })
        let shots = graph.shots.enumerated().map { index, segment -> StoryboardShotV2 in
            guard let output = byID[segment.id] else {
                return StoryboardShotV2(
                    id: segment.id,
                    observedFacts: ObservedShotFacts(facts: [], reviewFlags: ["missing-shot-understanding"])
                )
            }
            let flags = output.shot.observedFacts.reviewFlags
                + (review.contains(segment.id) ? ["cloud-local-alignment-needs-review"] : [])
                + ((finalAssembly.shots.first { $0.id == segment.id }?.classification == .evidencePoor) ? ["evidence-poor"] : [])
            let cloudFacts = cloud.evidence.filter {
                Self.overlaps($0.timeRange, segment.timeRange) && $0.rawText?.nilIfEmpty != nil
            }.map { evidence in
                GroundedFact(
                    field: evidence.kind == .transcript ? .audioSummary : .action,
                    value: evidence.rawText ?? "",
                    evidenceIDs: [evidence.id],
                    source: .cloudModel,
                    confidence: evidence.confidence,
                    reviewFlags: ["provider-evidence-aligned-to-local-shot"]
                )
            }
            let observed = ObservedShotFacts(
                facts: output.shot.observedFacts.facts + cloudFacts,
                unknownFields: output.shot.observedFacts.unknownFields,
                modelConfidence: output.shot.observedFacts.modelConfidence,
                reviewFlags: Array(Set(flags)).sorted()
            )
            return StoryboardShotV2(
                id: segment.id,
                observedFacts: observed,
                productionPlan: mergeProductionPlan(
                    primary: output.shot.productionPlan,
                    fallback: cloudPlans[segment.id]
                ),
                userLockedFields: output.shot.userLockedFields
            )
        }
        let summaries = understandings.compactMap(\.summary).unique
        let summary = cloud.globalSummary?.nilIfEmpty
            ?? summaries.joined(separator: " ").nilIfEmpty
            ?? "\(graph.shots.count) 个镜头；证据覆盖 \(finalAssembly.coverage.shotsWithEvidence)/\(finalAssembly.coverage.totalShots)。"
        var degradationNotes = [transcription.degradationNote, cloud.context.degradationNote]
            .compactMap { $0?.nilIfEmpty }
        degradationNotes.append(contentsOf: understandings.compactMap(\.degradationNote))
        let degradation = degradationNotes.unique.joined(separator: "; ").nilIfEmpty
        return StoryboardDocumentV2(
            id: "storyboard-\(run.id)",
            source: StoryboardSource(
                sourceID: source.id,
                runID: run.id,
                schemaVersion: 2,
                pipelineVersion: pipelineVersion,
                mode: .faithful,
                actualCloudMode: cloud.context.cloudMode,
                mediaUploaded: cloud.context.mediaUploaded,
                cloudTelemetry: cloud.context.telemetry,
                degradationNote: degradation
            ),
            shotGraph: graph,
            shots: shots,
            contentAnalysis: ContentAnalysis(
                title: understandings.compactMap(\.title).first,
                summary: summary,
                themes: understandings.flatMap(\.themes).unique,
                hook: understandings.compactMap(\.hook).first,
                retentionDevices: understandings.flatMap(\.retentionDevices).unique,
                payoff: understandings.compactMap(\.payoff).first,
                callToAction: understandings.compactMap(\.callToAction).first,
                referencedShotIDs: graph.shots.map(\.id)
            )
        )
    }

    private static func mergeProductionPlan(
        primary: ShotProductionPlan?,
        fallback: ShotProductionPlan?
    ) -> ShotProductionPlan? {
        guard let fallback else { return primary }
        guard let primary else { return fallback }
        return ShotProductionPlan(
            shotID: primary.shotID,
            sequenceID: primary.sequenceID ?? fallback.sequenceID,
            displayNumber: primary.displayNumber,
            purpose: primary.purpose ?? fallback.purpose,
            narrativeBeat: primary.narrativeBeat ?? fallback.narrativeBeat,
            hookRole: primary.hookRole ?? fallback.hookRole,
            targetDuration: primary.targetDuration ?? fallback.targetDuration,
            shotSize: primary.shotSize ?? fallback.shotSize,
            angle: primary.angle ?? fallback.angle,
            movement: primary.movement ?? fallback.movement,
            lensIntent: primary.lensIntent ?? fallback.lensIntent,
            subjectAction: primary.subjectAction ?? fallback.subjectAction,
            composition: primary.composition ?? fallback.composition,
            background: primary.background ?? fallback.background,
            lightingColor: primary.lightingColor ?? fallback.lightingColor,
            propsWardrobe: primary.propsWardrobe ?? fallback.propsWardrobe,
            dialogueOrVO: primary.dialogueOrVO ?? fallback.dialogueOrVO,
            onScreenCopy: primary.onScreenCopy ?? fallback.onScreenCopy,
            musicSFX: primary.musicSFX ?? fallback.musicSFX,
            transition: primary.transition ?? fallback.transition,
            continuity: primary.continuity ?? fallback.continuity,
            generationPrompt: primary.generationPrompt ?? fallback.generationPrompt,
            productionNotes: primary.productionNotes ?? fallback.productionNotes,
            sourceShotRefs: Array(Set(primary.sourceShotRefs + fallback.sourceShotRefs)).sorted(),
            confidence: primary.confidence ?? fallback.confidence,
            userLockedFields: primary.userLockedFields.union(fallback.userLockedFields),
            isDerivedCreativePlan: primary.isDerivedCreativePlan || fallback.isDerivedCreativePlan
        )
    }

    private static func qualityReport(
        _ base: QualityReport,
        document: StoryboardDocumentV2,
        transcription: TranscriptionArtifact,
        assembly: ShotEvidenceAssemblyResult,
        cloud: CloudStoryboardEnrichment
    ) -> QualityReport {
        var issues = base.issues
        if let note = transcription.degradationNote {
            issues.append(QualityIssue(code: "transcription-degraded", severity: .warning, shotID: nil, detail: note))
        }
        if let note = document.source.degradationNote, transcription.degradationNote == nil {
            issues.append(QualityIssue(code: "analysis-degraded", severity: .warning, shotID: nil, detail: note))
        }
        for id in assembly.coverage.orphanEvidenceIDs {
            issues.append(QualityIssue(code: "orphan-evidence", severity: .warning, shotID: nil, detail: id.rawValue))
        }
        for id in cloud.shotsNeedingReview {
            issues.append(QualityIssue(code: "cloud-local-conflict", severity: .warning, shotID: id, detail: "Cloud evidence needs review; local boundary remains authoritative."))
        }
        let status: QualityStatus
        if issues.contains(where: { $0.severity == .error }) {
            status = .failed
        } else if !cloud.shotsNeedingReview.isEmpty {
            status = .needsReview
        } else if document.source.degradationNote != nil {
            status = .degraded
        } else if assembly.coverage.shotsWithEvidence < assembly.coverage.totalShots {
            status = .partial
        } else {
            status = .clean
        }
        return QualityReport(
            status: status,
            issues: issues,
            machineFactCount: base.machineFactCount,
            groundedMachineFactCount: base.groundedMachineFactCount
        )
    }

    private static func overlaps(_ lhs: MediaTimeRange, _ rhs: MediaTimeRange) -> Bool {
        min(lhs.endSeconds, rhs.endSeconds) > max(lhs.startSeconds, rhs.startSeconds)
    }

    private static func overlaps(_ start: Double, _ end: Double, _ range: MediaTimeRange) -> Bool {
        min(end, range.endSeconds) > max(start, range.startSeconds)
    }

    private static func clampedRange(_ start: Double, _ end: Double, duration: Double) -> MediaTimeRange {
        let lower = min(max(0, start), max(0, duration - 0.001))
        let upper = min(duration, max(lower + 0.001, end))
        return MediaTimeRange(startSeconds: lower, endSeconds: upper)
    }

    private static func pointRange(_ time: Double, duration: Double) -> MediaTimeRange {
        clampedRange(time, time + max(0.001, 1 / 600), duration: duration)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private struct TranscriptionArtifact: Codable, Hashable, Sendable {
    let raw: [TranscriptSegment]
    let degradationNote: String?
}

private struct ShotUnderstandingCacheIdentity: Codable, Sendable {
    let pipelineVersion: String
    let shot: ShotSegment
    let displayNumber: Int
    let keyframes: [ShotKeyframe]
    let evidence: [EvidenceRef]
    let transcript: [TranscriptSegment]
    let onScreenText: [FrameText]
}

private struct ShotKeyframeCacheIdentity: Codable, Sendable {
    let pipelineVersion: String
    let shot: ShotSegment
    let framesPerShot: Int
}

private struct ShotEvidenceCacheIdentity: Codable, Sendable {
    let pipelineVersion: String
    let shot: ShotSegment
    let keyframes: [ShotKeyframe]
    let raw: [TranscriptSegment]
    let corrected: [TranscriptSegment]
    let ocr: [FrameText]
}

private struct IndexingArtifact: Codable, Hashable, Sendable {
    let legacy: Script
    let documentID: String
    let qualityStatus: QualityStatus
}

private struct CompletionArtifact: Codable, Hashable, Sendable {
    let completed: Bool
}

private extension FactField {
    static let allCasesForReview: [FactField] = [.subject, .action, .location, .shotSize, .cameraMovement, .visibleText, .audioSummary]
}

private extension Array where Element: Hashable {
    var unique: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
