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

    public init(
        document: StoryboardDocumentV2,
        legacy: Script,
        evidence: [EvidenceRef],
        quality: QualityReport,
        run: AnalysisRun
    ) {
        self.document = document
        self.legacy = legacy
        self.evidence = evidence
        self.quality = quality
        self.run = run
    }
}

public struct StoryboardExecutionContext: Codable, Hashable, Sendable {
    public let cloudMode: EffectiveCloudMode
    public let mediaUploaded: Bool
    public let degradationNote: String?

    public init(cloudMode: EffectiveCloudMode, mediaUploaded: Bool, degradationNote: String? = nil) {
        self.cloudMode = cloudMode
        self.mediaUploaded = mediaUploaded
        self.degradationNote = degradationNote
    }

    public static let local = StoryboardExecutionContext(cloudMode: .local, mediaUploaded: false)
}

public protocol EvidenceGroundedVideoAnalyzing: VideoAnalyzing {
    func analyzeGrounded(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> EvidenceGroundedAnalysis
}

public extension EvidenceGroundedVideoAnalyzing {
    func analyze(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> Script {
        try await analyzeGrounded(source, onStage: onStage).legacy
    }
}

/// Production adapter that makes the authoritative graph and V2 document the
/// source of truth while retaining the established Script consumers through a
/// single deterministic projection.
public struct EvidenceGroundedVideoAnalyzer: EvidenceGroundedVideoAnalyzing {
    private let base: any VideoAnalyzing
    private let probe: any VideoAssetProbing
    private let detector: any ShotBoundaryDetecting
    private let keyframeSelector: any ShotKeyframeSelecting
    private let artifactStore: AnalysisArtifactStore
    private let pipelineVersion: String
    private let quality: AnalysisQuality
    private let makeRunID: @Sendable () -> String
    private let executionContext: @Sendable (VideoAssetDescriptor) async -> StoryboardExecutionContext

    public init(
        base: any VideoAnalyzing,
        probe: any VideoAssetProbing,
        detector: any ShotBoundaryDetecting,
        keyframeSelector: any ShotKeyframeSelecting,
        artifactStore: AnalysisArtifactStore,
        pipelineVersion: String = "storyboard-v2.0",
        quality: AnalysisQuality = .balanced,
        runID: @escaping @Sendable () -> String = { UUID().uuidString },
        executionContext: @escaping @Sendable (VideoAssetDescriptor) async -> StoryboardExecutionContext = { _ in .local }
    ) {
        self.base = base
        self.probe = probe
        self.detector = detector
        self.keyframeSelector = keyframeSelector
        self.artifactStore = artifactStore
        self.pipelineVersion = pipelineVersion
        self.quality = quality
        self.makeRunID = runID
        self.executionContext = executionContext
    }

    public func analyzeGrounded(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> EvidenceGroundedAnalysis {
        let encoder = Self.encoder()
        let asset = try await probe.probe(source)
        let context = await executionContext(asset)
        var run = try await artifactStore.createRun(
            clipID: source.id,
            fingerprint: asset.fingerprint,
            pipelineVersion: pipelineVersion,
            runID: makeRunID()
        )
        run = try await artifactStore.commit(stage: .assetProbe, artifact: try encoder.encode(asset), for: run)

        let graph = try await detector.detect(in: asset, sourceURL: source.localFileURL, quality: quality)
        run = try await artifactStore.commit(stage: .shotDetection, artifact: try encoder.encode(graph), for: run)
        let keyframes = try await keyframeSelector.select(in: graph, sourceURL: source.localFileURL)
        run = try await artifactStore.commit(stage: .keyframes, artifact: try encoder.encode(keyframes), for: run)

        let baseScript = try await base.analyze(source, onStage: onStage)
        let assembly = Self.assemble(graph: graph, script: baseScript, keyframes: keyframes)
        let document = StoryboardDocumentV2(
            id: "storyboard-\(run.id)",
            source: StoryboardSource(
                sourceID: source.id,
                runID: run.id,
                schemaVersion: 2,
                pipelineVersion: pipelineVersion,
                mode: .faithful,
                actualCloudMode: context.cloudMode,
                mediaUploaded: context.mediaUploaded,
                degradationNote: [baseScript.degradationNote, context.degradationNote]
                    .compactMap { $0 }.joined(separator: "; ").nilIfEmpty
            ),
            shotGraph: graph,
            shots: assembly.shots,
            contentAnalysis: ContentAnalysis(
                title: baseScript.title,
                summary: baseScript.summary,
                themes: baseScript.visualElements,
                hook: baseScript.hookStructure?.openingHook,
                retentionDevices: baseScript.hookStructure?.retentionDevices ?? [],
                payoff: baseScript.hookStructure?.payoff,
                callToAction: baseScript.hookStructure?.callToAction,
                referencedShotIDs: graph.shots.map(\.id)
            )
        )
        run = try await artifactStore.commit(stage: .synthesis, artifact: try encoder.encode(document), for: run)
        let report = StoryboardValidator.validate(document: document, evidence: assembly.evidence)
        run = try await artifactStore.commit(stage: .quality, artifact: try encoder.encode(report), for: run)
        let legacy = StoryboardLegacyProjector.project(document, createdAt: baseScript.createdAt)
        return EvidenceGroundedAnalysis(
            document: document,
            legacy: legacy,
            evidence: assembly.evidence,
            quality: report,
            run: run
        )
    }

    private static func assemble(
        graph: ShotGraph,
        script: Script,
        keyframes: [ShotKeyframe]
    ) -> (shots: [StoryboardShotV2], evidence: [EvidenceRef]) {
        let keys = Dictionary(uniqueKeysWithValues: keyframes.map { ($0.shotID, $0) })
        var evidence: [EvidenceRef] = []
        var documents: [StoryboardShotV2] = []
        for (index, segment) in graph.shots.enumerated() {
            let legacy = script.shots.max { lhs, rhs in
                overlap(lhs, segment) < overlap(rhs, segment)
            }
            var facts: [GroundedFact] = []
            if let key = keys[segment.id] {
                let id = EvidenceID(rawValue: "frame:\(segment.id.rawValue)")
                evidence.append(EvidenceRef(
                    id: id, kind: .frame, timeRange: segment.timeRange,
                    frameRange: segment.frameRange, payloadRef: key.artifactRef,
                    source: .deterministic, confidence: segment.boundaryConfidence
                ))
                if let visual = normalized(legacy?.visualDescription) {
                    facts.append(GroundedFact(
                        field: .action, value: visual, evidenceIDs: [id],
                        source: .onDeviceModel, confidence: 0.75
                    ))
                }
            }
            if let narration = normalized(legacy?.narration) {
                let id = EvidenceID(rawValue: "transcript:\(segment.id.rawValue)")
                evidence.append(EvidenceRef(
                    id: id, kind: .transcript, timeRange: segment.timeRange,
                    frameRange: nil, payloadRef: "transcript/\(segment.id.rawValue).txt",
                    source: .deterministic, confidence: 0.8, rawText: narration
                ))
                facts.append(GroundedFact(
                    field: .audioSummary, value: narration, evidenceIDs: [id],
                    source: .onDeviceModel, confidence: 0.8
                ))
            }
            for (textIndex, text) in (legacy?.onScreenText ?? []).enumerated() {
                let id = EvidenceID(rawValue: "ocr:\(segment.id.rawValue):\(textIndex)")
                evidence.append(EvidenceRef(
                    id: id, kind: .ocr, timeRange: segment.timeRange,
                    frameRange: segment.frameRange,
                    payloadRef: "ocr/\(segment.id.rawValue)-\(textIndex).txt",
                    source: .deterministic, confidence: 0.8, rawText: text
                ))
                facts.append(GroundedFact(
                    field: .visibleText, value: text, evidenceIDs: [id],
                    source: .onDeviceModel, confidence: 0.8
                ))
            }
            let plan = ShotProductionPlan(
                shotID: segment.id,
                displayNumber: index + 1,
                purpose: legacy.flatMap { normalized($0.pacingNote) },
                subjectAction: legacy.flatMap { normalized($0.visualDescription) },
                dialogueOrVO: legacy.flatMap { normalized($0.narration) },
                onScreenCopy: legacy?.onScreenText.joined(separator: " / "),
                sourceShotRefs: [segment.id],
                confidence: facts.map(\.confidence).min(),
                isDerivedCreativePlan: true
            )
            documents.append(StoryboardShotV2(
                id: segment.id,
                observedFacts: ObservedShotFacts(facts: facts),
                productionPlan: plan
            ))
        }
        return (documents, evidence)
    }

    private static func overlap(_ shot: StoryboardShot, _ segment: ShotSegment) -> Double {
        max(0, min(shot.endSeconds, segment.timeRange.endSeconds) - max(shot.startSeconds, segment.timeRange.startSeconds))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
