import AppGroupSupport
@testable import AppShell
import ClipCore
import ClipDigest
import CloudVision
import CoreGraphics
import EngineKit
import Foundation
import ImageIO
import MemoryFeature
import ModelStore
import Persistence
import RAGCore
import SettingsFeature
import StoryboardCore
import StoryboardExport
import Testing
import UniformTypeIdentifiers
import VideoUnderstanding

@Suite(.serialized)
struct SavedCloudProductionAssemblyTests {
    @MainActor
    @Test func savedLASSettingsFlowThroughAppDependenciesAndRetrievalAssembly() async throws {
      try await AppShellKeychainTestMutex.shared.withMainActorLock {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EngramSavedCloudAssembly-\(UUID().uuidString)", isDirectory: true)
        let suite = "EngramSavedCloudAssembly-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let accounts = VisionBackendKeychainAccount.allAccounts
        let existing = Dictionary(uniqueKeysWithValues: accounts.map { ($0, KeychainStore.string(for: $0)) })
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            for account in accounts { KeychainStore.set(existing[account] ?? nil, for: account) }
        }
        for account in accounts { KeychainStore.set(nil, for: account) }

        let now = Date()
        let store = CloudSettingsStore(defaults: defaults)
        store.save(VisionBackendSettings(
            requestedMode: .lasDeep,
            las: LASBackendSettings(
                isEnabled: true,
                videoStoryboardOperatorID: LASOperatorContract.videoStoryboard.operatorID,
                videoFineUnderstandingOperatorID: LASOperatorContract.videoFineUnderstanding.operatorID,
                scriptGenerationOperatorID: LASOperatorContract.scriptGeneration.operatorID,
                enhancedASROperatorID: LASOperatorContract.enhancedASR.operatorID
            ),
            staging: TOSStagingSettings(
                bucket: "fixture-bucket",
                objectPrefix: "engram/runs/",
                credentialReferenceID: "fixture-sts",
                temporaryCredentialExpiresAt: now.addingTimeInterval(3_600),
                maximumUploadMegabytes: 10
            )
        ))
        try #require(store.setCredential(.lasAPIKey, value: "las-secret"))
        try #require(store.setCredential(.tosAccessKeyID, value: "sts-access"))
        try #require(store.setCredential(.tosSecretAccessKey, value: "sts-secret"))
        try #require(store.setCredential(.tosSecurityToken, value: "sts-token"))
        let fingerprints = store.configurationFingerprints()
        for role in CloudProviderRole.lasDeepRoles {
            store.saveCapabilitySnapshot(savedAssemblyCapability(
                role: role,
                fingerprint: try #require(fingerprints[role]),
                now: now
            ))
        }

        let locations = try productionAssemblyLocations(root: root)
        let container = try PersistenceStack.makeContainer(inMemory: true)
        let engine = ProductionAssemblyEngine()
        let ledger = ProductionAssemblyLedger()
        let videoRuntime = VideoPipelineRuntime(
            probe: ProductionAssemblyProbe(ledger: ledger),
            detector: ProductionAssemblyDetector(ledger: ledger),
            keyframeSelector: ProductionAssemblyKeyframes(ledger: ledger),
            transcriber: ProductionAssemblyTranscriber(ledger: ledger),
            recognizer: ProductionAssemblyOCR(ledger: ledger),
            understandingProvider: ProductionAssemblyEvidenceOnlyUnderstanding(ledger: ledger),
            pipelineVersion: "saved-cloud-production-v1",
            representativeFramesPerShot: 2,
            runID: { "run-saved-cloud-production" }
        )
        let stager = RecordingTOSStager(now: now)
        let client = RecordingLASClient(includesArtifacts: true)
        let dependencies = AppDependencies(
            engines: [engine],
            activeEngine: engine,
            modelStore: ModelStore(modelsDirectory: locations.modelsDirectory),
            activeModel: productionAssemblyModel,
            defaults: defaults,
            modelContainer: container,
            appGroupLocations: locations,
            retrievalEmbeddingEngine: ProductionAssemblyEmbedding(),
            cloudAnalysisRuntime: CloudAnalysisRuntime(
                makeLASClient: { _ in client },
                makeTOSStager: { _ in stager },
                sleep: { _ in },
                now: { now }
            ),
            videoPipelineRuntime: videoRuntime
        )
        await dependencies.authorizeNextCloudAnalysisRun()
        let memory = dependencies.makeMemoryViewModel()
        let picked = root.appendingPathComponent("saved-cloud.mov")
        try Data([0x01, 0x02, 0x03]).write(to: picked)

        await memory.importVideo(.file(picked))
        await memory.digestAndRefresh()

        let item = try #require(memory.items.first)
        let storyboard = try #require(item.storyboard)
        #expect(item.state == .indexed)
        #expect(storyboard.source.actualCloudMode == .cloudDeep)
        #expect(storyboard.source.mediaUploaded)
        #expect(storyboard.source.cloudTelemetry?.requestedMode == "lasDeep")
        #expect(storyboard.source.cloudTelemetry?.effectiveMode == "lasDeep")
        #expect(storyboard.source.cloudTelemetry?.cleanupState == "deleted")
        #expect(item.qualityStatusRaw == "needsReview")
        #expect(storyboard.shotGraph.shots.map(\.timeRange) == [
            MediaTimeRange(startSeconds: 0, endSeconds: 1),
            MediaTimeRange(startSeconds: 1, endSeconds: 2),
        ])
        #expect(storyboard.contentAnalysis.summary.contains("Grounded generated script"))
        #expect(storyboard.shots.map { $0.productionPlan?.subjectAction } == [
            "LAS cloud action one",
            "LAS cloud action two",
        ])
        #expect(storyboard.shots.map { $0.productionPlan?.dialogueOrVO } == [
            "LAS cloud dialogue one",
            "LAS cloud dialogue two",
        ])
        #expect(storyboard.shots[1].productionPlan?.targetDuration == 0.8)
        #expect(storyboard.shots.enumerated().allSatisfy { index, shot in
            shot.productionPlan?.sourceShotRefs == [shot.id]
                && shot.productionPlan?.isDerivedCreativePlan == true
                && storyboard.shotGraph.shots[index].id == shot.id
        })
        #expect(storyboard.shots.flatMap(\.observedFacts.facts).contains(where: {
            $0.source == .cloudModel && $0.value.contains("A verified provider scene")
        }))
        let cloudFacts = storyboard.shots.flatMap(\.observedFacts.facts).filter { $0.source == .cloudModel }
        #expect(cloudFacts.contains { $0.field == .action && $0.value.contains("A verified provider scene") })
        #expect(cloudFacts.contains { $0.field == .audioSummary && $0.value == "A spoken line." })
        #expect(cloudFacts.allSatisfy { fact in
            !fact.evidenceIDs.isEmpty && fact.evidenceIDs.allSatisfy { $0.rawValue.hasPrefix("cloud:") }
        })
        #expect(await stager.newUploadCount == 1)
        #expect(await client.submittedContracts == [
            .videoStoryboard,
            .videoFineUnderstanding,
            .scriptGeneration,
            .enhancedASR,
        ])

        let edited = try #require(await memory.editStoryboardShot(
            item,
            shotIndex: 0,
            command: .editDialogue("user locked LAS dialogue")
        ))
        #expect(edited.document.shots[0].productionPlan?.dialogueOrVO == "user locked LAS dialogue")
        #expect(edited.document.shots[0].userLockedFields.contains(EditablePlanField.dialogueOrVO.rawValue))

        let editedItem = try #require(memory.items.first)
        let rerun = try #require(await memory.editStoryboardShot(
            editedItem,
            shotIndex: 0,
            command: .reanalyze
        ))
        #expect(rerun.document.shots[0].productionPlan?.dialogueOrVO == "user locked LAS dialogue")
        #expect(rerun.document.shots[0].productionPlan?.subjectAction == "LAS cloud action one")
        #expect(rerun.document.shots[0].observedFacts.facts.contains { $0.source == .cloudModel })

        let exportRoot = root.appendingPathComponent("las-cloud-export", isDirectory: true)
        let bundle = try StoryboardExporter().export(
            rerun.document,
            keyframes: try productionAssemblyExportKeyframes(for: rerun.document),
            to: exportRoot
        )
        let validation = StoryboardExportValidator.validate(bundle, document: rerun.document)
        #expect(validation.isValid)
        #expect(Set(bundle.artifacts.map(\.format)) == Set(StoryboardExportFormat.allCases))
        let markdown = try String(contentsOf: productionArtifactURL(.markdown, in: bundle), encoding: .utf8)
        let CSV = try String(contentsOf: productionArtifactURL(.csv, in: bundle), encoding: .utf8)
        let JSON = try String(contentsOf: productionArtifactURL(.json, in: bundle), encoding: .utf8)
        #expect(markdown.contains("LAS cloud action one"))
        #expect(markdown.contains("user locked LAS dialogue"))
        #expect(CSV.contains("LAS cloud copy two"))
        #expect(JSON.contains("LAS cloud note two"))
        #expect(try Data(contentsOf: productionArtifactURL(.pdf, in: bundle)).count > 1_000)
        let referencePackage = try productionArtifactURL(.referenceFramePackage, in: bundle)
        #expect(FileManager.default.fileExists(
            atPath: referencePackage.appendingPathComponent("manifest.json").path
        ))
      }
    }

    @MainActor
    @Test func savedHybridRunsLASFirstAndSendsOnlySelectedShotToArkRefinement() async throws {
      try await AppShellKeychainTestMutex.shared.withMainActorLock {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EngramSavedHybridAssembly-\(UUID().uuidString)", isDirectory: true)
        let suite = "EngramSavedHybridAssembly-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let accounts = VisionBackendKeychainAccount.allAccounts
        let existing = Dictionary(uniqueKeysWithValues: accounts.map { ($0, KeychainStore.string(for: $0)) })
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            for account in accounts { KeychainStore.set(existing[account] ?? nil, for: account) }
        }
        for account in accounts { KeychainStore.set(nil, for: account) }

        let now = Date()
        let store = CloudSettingsStore(defaults: defaults)
        store.save(VisionBackendSettings(
            requestedMode: .hybridMaximum,
            ark: ArkBackendSettings(
                textModelID: "ep-text",
                frameModelID: "ep-frame"
            ),
            las: LASBackendSettings(isEnabled: true),
            staging: TOSStagingSettings(
                bucket: "fixture-bucket",
                objectPrefix: "engram/runs/",
                credentialReferenceID: "fixture-sts",
                temporaryCredentialExpiresAt: now.addingTimeInterval(3_600),
                maximumUploadMegabytes: 10
            )
        ))
        try #require(store.setCredential(.arkAPIKey, value: "ark-secret"))
        try #require(store.setCredential(.lasAPIKey, value: "las-secret"))
        try #require(store.setCredential(.tosAccessKeyID, value: "sts-access"))
        try #require(store.setCredential(.tosSecretAccessKey, value: "sts-secret"))
        try #require(store.setCredential(.tosSecurityToken, value: "sts-token"))
        let fingerprints = store.configurationFingerprints()
        for role in CloudProviderRole.lasDeepRoles.union(CloudProviderRole.arkStandardRoles) {
            store.saveCapabilitySnapshot(savedAssemblyCapability(
                role: role,
                fingerprint: try #require(fingerprints[role]),
                now: now
            ))
        }

        let locations = try productionAssemblyLocations(root: root)
        let container = try PersistenceStack.makeContainer(inMemory: true)
        let engine = ProductionAssemblyEngine()
        let ledger = ProductionAssemblyLedger()
        let runtime = VideoPipelineRuntime(
            probe: ProductionAssemblyProbe(ledger: ledger),
            detector: ProductionAssemblyDetector(ledger: ledger),
            keyframeSelector: ProductionAssemblyKeyframes(ledger: ledger),
            transcriber: ProductionAssemblyTranscriber(ledger: ledger),
            recognizer: ProductionAssemblyOCR(ledger: ledger),
            understandingProvider: ProductionAssemblyUnderstanding(ledger: ledger),
            refinementUnderstandingProvider: ProductionAssemblyRefinementUnderstanding(ledger: ledger),
            pipelineVersion: "saved-hybrid-production-v1",
            runID: { "run-saved-hybrid-production" }
        )
        let stager = RecordingTOSStager(now: now)
        let client = RecordingLASClient()
        let dependencies = AppDependencies(
            engines: [engine],
            activeEngine: engine,
            modelStore: ModelStore(modelsDirectory: locations.modelsDirectory),
            activeModel: productionAssemblyModel,
            defaults: defaults,
            modelContainer: container,
            appGroupLocations: locations,
            retrievalEmbeddingEngine: ProductionAssemblyEmbedding(),
            cloudAnalysisRuntime: CloudAnalysisRuntime(
                makeLASClient: { _ in client },
                makeTOSStager: { _ in stager },
                sleep: { _ in },
                now: { now }
            ),
            videoPipelineRuntime: runtime
        )
        await dependencies.authorizeNextCloudAnalysisRun()
        let memory = dependencies.makeMemoryViewModel()
        let picked = root.appendingPathComponent("saved-hybrid.mov")
        try Data([0x01, 0x02, 0x03]).write(to: picked)

        await memory.importVideo(.file(picked))
        await memory.digestAndRefresh()

        let storyboard = try #require(memory.items.first?.storyboard)
        #expect(storyboard.source.cloudTelemetry?.requestedMode == "hybridMaximum")
        #expect(storyboard.source.cloudTelemetry?.effectiveMode == "lasArkRefine")
        #expect(await ledger.understandingShotIDs == [ShotID(rawValue: "S001"), ShotID(rawValue: "S002")])
        #expect(await ledger.refinementShotIDs == [ShotID(rawValue: "S001")])
        #expect(storyboard.source.cloudTelemetry?.refinementShotIDs == ["S001"])
      }
    }
}

@MainActor
@Test func retrievalAssemblyBuildsTheRealStoryboardPipelineAndSurvivesRestart() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramStoryboardProductionAssembly-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = try productionAssemblyLocations(root: root)
    let container = try PersistenceStack.makeContainer(inMemory: true)
    let engine = ProductionAssemblyEngine()
    let ledger = ProductionAssemblyLedger()
    let runtime = RetrievalAssembly.VideoPipelineRuntime(
        probe: ProductionAssemblyProbe(ledger: ledger),
        detector: ProductionAssemblyDetector(ledger: ledger),
        keyframeSelector: ProductionAssemblyKeyframes(ledger: ledger),
        transcriber: ProductionAssemblyTranscriber(ledger: ledger),
        recognizer: ProductionAssemblyOCR(ledger: ledger),
        understandingProvider: ProductionAssemblyUnderstanding(ledger: ledger),
        pipelineVersion: "production-assembly-v1",
        representativeFramesPerShot: 2,
        runID: { "run-production-assembly" }
    )

    let first = try RetrievalAssembly.makeServices(
        modelContainer: container,
        modelStore: ModelStore(modelsDirectory: locations.modelsDirectory),
        activeEngine: engine,
        activeModel: productionAssemblyModel,
        generationConfig: .default,
        appGroupLocations: locations,
        embeddingEngine: ProductionAssemblyEmbedding(),
        videoPipelineRuntime: runtime
    )
    let firstDependencies = AppDependencies(
        engines: [engine],
        activeEngine: engine,
        activeModel: productionAssemblyModel,
        defaults: nil,
        clipDigestService: first.clipDigestService,
        retriever: first.retriever
    )
    let firstMemory = firstDependencies.makeMemoryViewModel()
    let picked = root.appendingPathComponent("two-shot.mov")
    try Data([0x01, 0x02, 0x03]).write(to: picked)

    await firstMemory.importVideo(.file(picked))
    await firstMemory.digestAndRefresh()

    let indexed = try #require(firstMemory.items.first)
    let original = try #require(indexed.storyboard)
    #expect(indexed.state == .indexed)
    #expect(original.shots.count == 2)
    #expect(original.shotGraph.shots.allSatisfy { $0.representativeFrameRefs.count == 2 })
    #expect(indexed.activeRunID == "run-production-assembly")
    #expect(await ledger.probeCalls == 1)
    #expect(await ledger.detectorCalls == 1)
    #expect(await ledger.understandingShotIDs == [ShotID(rawValue: "S001"), ShotID(rawValue: "S002")])

    let edited = try #require(await firstMemory.editStoryboardShot(
        indexed,
        shotIndex: 0,
        command: .editDialogue("persisted dialogue")
    ))
    #expect(edited.document.shots[0].productionPlan?.dialogueOrVO == "persisted dialogue")
    #expect(edited.document.shots[0].userLockedFields.contains(EditablePlanField.dialogueOrVO.rawValue))

    // Rebuild the real RetrievalAssembly and Memory client over the same stores. No whole
    // VideoAnalyzing fake is injected, so this exercises the production orchestrator seam.
    let restarted = try RetrievalAssembly.makeServices(
        modelContainer: container,
        modelStore: ModelStore(modelsDirectory: locations.modelsDirectory),
        activeEngine: engine,
        activeModel: productionAssemblyModel,
        generationConfig: .default,
        appGroupLocations: locations,
        embeddingEngine: ProductionAssemblyEmbedding(),
        videoPipelineRuntime: runtime
    )
    let restartedDependencies = AppDependencies(
        engines: [engine],
        activeEngine: engine,
        activeModel: productionAssemblyModel,
        defaults: nil,
        clipDigestService: restarted.clipDigestService,
        retriever: restarted.retriever
    )
    let restartedMemory = restartedDependencies.makeMemoryViewModel()
    await restartedMemory.refresh()
    let persistedEdit = try #require(restartedMemory.items.first)
    let undo = try #require(await restartedMemory.editStoryboardShot(persistedEdit, shotIndex: 0, command: .undo))
    #expect(undo.document.shots[0].productionPlan?.dialogueOrVO == original.shots[0].productionPlan?.dialogueOrVO)

    await restartedMemory.refresh()
    let restored = try #require(restartedMemory.items.first)
    _ = try #require(await restartedMemory.editStoryboardShot(restored, shotIndex: 1, command: .reanalyze))
    #expect(await ledger.requestedKeyframeShotIDs.last == [ShotID(rawValue: "S002")])
}

private let productionAssemblyModel = ModelIdentity(
    id: "production-assembly-model",
    family: "fixture",
    quantization: "none",
    contextLength: 1_024,
    estimatedMemoryBytes: 0
)

private actor ProductionAssemblyEngine: LLMEngine {
    nonisolated let descriptor = EngineDescriptor(id: "production-assembly", displayName: "Production Assembly", kind: .mlx)
    func load(_ model: ModelIdentity) async throws {}
    func unload() async {}
    func generate(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(.stop, GenerationMetrics(firstTokenLatencyMillis: 0, tokensPerSecond: 0, outputTokenCount: 0)))
            continuation.finish()
        }
    }
    func countTokens(in text: String) async throws -> Int { text.count }
}

private actor ProductionAssemblyLedger {
    private(set) var probeCalls = 0
    private(set) var detectorCalls = 0
    private(set) var understandingShotIDs: [ShotID] = []
    private(set) var refinementShotIDs: [ShotID] = []
    private(set) var requestedKeyframeShotIDs: [[ShotID]] = []
    func recordProbe() { probeCalls += 1 }
    func recordDetector() { detectorCalls += 1 }
    func recordUnderstanding(_ id: ShotID) { understandingShotIDs.append(id) }
    func recordRefinement(_ id: ShotID) { refinementShotIDs.append(id) }
    func recordKeyframes(_ ids: Set<ShotID>) { requestedKeyframeShotIDs.append(ids.sorted()) }
}

private struct ProductionAssemblyProbe: VideoAssetProbing {
    let ledger: ProductionAssemblyLedger
    func probe(_ source: VideoSource) async throws -> VideoAssetDescriptor {
        await ledger.recordProbe()
        return VideoAssetDescriptor(
            sourceID: source.id,
            durationSeconds: 2,
            nominalFrameRate: 30,
            frameCount: 60,
            width: 720,
            height: 1280,
            timescale: 600,
            codec: "fixture",
            hasAudio: true,
            fileSizeBytes: 3,
            fingerprint: SourceFingerprint(value: "production-assembly-fingerprint")
        )
    }
}

private struct ProductionAssemblyDetector: ShotBoundaryDetecting {
    let ledger: ProductionAssemblyLedger
    func detect(in asset: VideoAssetDescriptor, sourceURL: URL, quality: AnalysisQuality) async throws -> ShotGraph {
        await ledger.recordDetector()
        return try ShotGraph(asset: asset, shots: [
            ShotSegment(
                id: ShotID(rawValue: "S001"),
                timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 1),
                frameRange: FrameRange(startFrame: 0, endFrameExclusive: 30),
                transitionIn: .start,
                transitionOut: .cut,
                boundaryConfidence: 0.95,
                detectorEvidenceIDs: ["detector:S001"],
                representativeFrameRefs: ["shots/S001/representative-1.jpg", "shots/S001/representative-2.jpg"]
            ),
            ShotSegment(
                id: ShotID(rawValue: "S002"),
                timeRange: MediaTimeRange(startSeconds: 1, endSeconds: 2),
                frameRange: FrameRange(startFrame: 30, endFrameExclusive: 60),
                transitionIn: .cut,
                transitionOut: .end,
                boundaryConfidence: 0.95,
                detectorEvidenceIDs: ["detector:S002"],
                representativeFrameRefs: ["shots/S002/representative-1.jpg", "shots/S002/representative-2.jpg"]
            ),
        ])
    }
}

private struct ProductionAssemblyKeyframes: ShotKeyframeSelecting {
    let ledger: ProductionAssemblyLedger
    func select(in graph: ShotGraph, sourceURL: URL) async throws -> [ShotKeyframe] {
        try await select(in: graph, sourceURL: sourceURL, shotIDs: Set(graph.shots.map(\.id)), framesPerShot: 2)
    }
    func select(
        in graph: ShotGraph,
        sourceURL: URL,
        shotIDs: Set<ShotID>,
        framesPerShot: Int
    ) async throws -> [ShotKeyframe] {
        await ledger.recordKeyframes(shotIDs)
        return graph.shots.filter { shotIDs.contains($0.id) }.flatMap { shot in
            (0..<min(2, max(1, framesPerShot))).map { index in
                let duration = shot.timeRange.endSeconds - shot.timeRange.startSeconds
                let time = shot.timeRange.startSeconds + (Double(index + 1) / 3) * duration
                return ShotKeyframe(
                    shotID: shot.id,
                    frame: SampledFrame(timestampSeconds: time, jpegData: Data([0xff, 0xd8, UInt8(index), 0xff, 0xd9])),
                    artifactRef: "shots/\(shot.id.rawValue)/representative-\(index + 1).jpg"
                )
            }
        }
    }
}

private struct ProductionAssemblyTranscriber: Transcriber {
    let ledger: ProductionAssemblyLedger
    func transcribe(_ source: VideoSource) async throws -> [TranscriptSegment] {
        [
            TranscriptSegment(startSeconds: 0.1, endSeconds: 0.8, text: "first line"),
            TranscriptSegment(startSeconds: 1.1, endSeconds: 1.8, text: "second line"),
        ]
    }
}

private struct ProductionAssemblyOCR: FrameTextRecognizing {
    let ledger: ProductionAssemblyLedger
    func recognizeText(in source: VideoSource) async -> [FrameText] { [] }
}

private struct ProductionAssemblyUnderstanding: ShotUnderstandingProviding {
    let ledger: ProductionAssemblyLedger
    func understand(_ input: ShotUnderstandingInput, displayNumber: Int) async throws -> ShotUnderstandingOutput {
        await ledger.recordUnderstanding(input.shot.id)
        let frameEvidence = input.evidence.filter { $0.kind == .frame }.map(\.id)
        let fact = GroundedFact(
            field: .action,
            value: "action \(displayNumber)",
            evidenceIDs: frameEvidence,
            source: .onDeviceModel,
            confidence: 0.9
        )
        return ShotUnderstandingOutput(
            shot: StoryboardShotV2(
                id: input.shot.id,
                observedFacts: ObservedShotFacts(facts: [fact]),
                productionPlan: ShotProductionPlan(
                    shotID: input.shot.id,
                    displayNumber: displayNumber,
                    subjectAction: fact.value,
                    dialogueOrVO: input.transcript.first?.text,
                    sourceShotRefs: [input.shot.id],
                    isDerivedCreativePlan: true
                )
            ),
            title: "Production Assembly",
            summary: "Two grounded shots"
        )
    }
}

private struct ProductionAssemblyEvidenceOnlyUnderstanding: ShotUnderstandingProviding {
    let ledger: ProductionAssemblyLedger
    func understand(_ input: ShotUnderstandingInput, displayNumber: Int) async throws -> ShotUnderstandingOutput {
        await ledger.recordUnderstanding(input.shot.id)
        let evidenceIDs = input.evidence.filter { $0.kind == .transcript }.map(\.id)
        let fact = GroundedFact(
            field: .audioSummary,
            value: input.transcript.map(\.text).joined(separator: " "),
            evidenceIDs: evidenceIDs,
            source: .deterministic,
            confidence: 1
        )
        return ShotUnderstandingOutput(
            shot: StoryboardShotV2(
                id: input.shot.id,
                observedFacts: ObservedShotFacts(facts: [fact], unknownFields: [.action])
            )
        )
    }
}

private struct ProductionAssemblyRefinementUnderstanding: ShotUnderstandingProviding {
    let ledger: ProductionAssemblyLedger
    func understand(_ input: ShotUnderstandingInput, displayNumber: Int) async throws -> ShotUnderstandingOutput {
        await ledger.recordRefinement(input.shot.id)
        let frameEvidence = input.evidence.filter { $0.kind == .frame }.map(\.id)
        let fact = GroundedFact(
            field: .action,
            value: "ark selected refinement \(displayNumber)",
            evidenceIDs: frameEvidence,
            source: .cloudModel,
            confidence: 0.95
        )
        return ShotUnderstandingOutput(
            shot: StoryboardShotV2(
                id: input.shot.id,
                observedFacts: ObservedShotFacts(facts: [fact]),
                productionPlan: ShotProductionPlan(
                    shotID: input.shot.id,
                    displayNumber: displayNumber,
                    subjectAction: fact.value,
                    sourceShotRefs: [input.shot.id],
                    isDerivedCreativePlan: true
                )
            )
        )
    }
}

private actor ProductionAssemblyEmbedding: EmbeddingEngine {
    nonisolated let metadata = EmbeddingEngineMetadata(id: "production-assembly-embedding", displayName: "Fixture", dimension: 4)
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in [Float(text.count), 1, 0, 0] }
    }
}

private func productionAssemblyLocations(root: URL) throws -> AppGroupLocations {
    let locations = AppGroupLocations(
        groupIdentifier: "group.com.gxfn.engram.production-assembly-tests",
        rootDirectory: root,
        storeURL: root.appendingPathComponent("Engram.store"),
        queueDirectory: root.appendingPathComponent("queue", isDirectory: true),
        modelsDirectory: root.appendingPathComponent("Models", isDirectory: true),
        videosDirectory: root.appendingPathComponent("videos", isDirectory: true),
        retrievalIndexURL: root.appendingPathComponent("retrieval.sqlite"),
        usesAppGroupContainer: false
    )
    for directory in [locations.rootDirectory, locations.queueDirectory, locations.modelsDirectory, locations.videosDirectory] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return locations
}

private func productionAssemblyExportKeyframes(
    for document: StoryboardDocumentV2
) throws -> [ShotKeyframe] {
    let JPEG = try productionAssemblyJPEG()
    return document.shotGraph.shots.flatMap { shot in
        shot.representativeFrameRefs.enumerated().map { index, reference in
            let fraction = Double(index + 1) / Double(shot.representativeFrameRefs.count + 1)
            return ShotKeyframe(
                shotID: shot.id,
                frame: SampledFrame(
                    timestampSeconds: shot.timeRange.startSeconds
                        + fraction * (shot.timeRange.endSeconds - shot.timeRange.startSeconds),
                    jpegData: JPEG
                ),
                artifactRef: reference
            )
        }
    }
}

private func productionAssemblyJPEG() throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: 4,
        height: 4,
        bitsPerComponent: 8,
        bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

private func productionArtifactURL(
    _ format: StoryboardExportFormat,
    in bundle: StoryboardExportBundle
) throws -> URL {
    try #require(bundle.artifacts.first(where: { $0.format == format })?.url)
}

private func savedAssemblyCapability(
    role: CloudProviderRole,
    fingerprint: String,
    now: Date
) -> CloudRoleCapabilitySnapshot {
    CloudRoleCapabilitySnapshot(
        role: role,
        providerKind: role.providerKind,
        profileID: "production-\(role.rawValue)",
        configurationFingerprint: fingerprint,
        credentialScheme: role == .mediaStaging ? .temporarySTS : .apiKey,
        credentialReferenceID: "credential-\(role.rawValue)",
        probeLevel: .liveMedia,
        status: .available,
        observedCapabilities: [role.rawValue],
        acceptedMediaKinds: role == .lasEnhancedASR ? [.tosObject, .video] : [.tosObject],
        limits: CloudObservedLimits(maximumBytes: 10_000_000, maximumDurationSeconds: 3_600),
        supportsAsync: true,
        supportsIdempotency: false,
        supportsCancellation: false,
        reportsUsage: true,
        lastProbedAt: now,
        expiresAt: now.addingTimeInterval(86_400),
        officialContractRevision: "volcengine-las-operator-docs-2026-07-13-v2",
        sanitizedEvidenceCode: "mock-wire-only"
    )
}
