@testable import AppShell
import ClipDigest
import CloudVision
import Foundation
import StoryboardCore
import Testing
import VideoUnderstanding

@Test func lasOnlyOrchestratorStagesOnceRunsFourOfficialRolesAndKeepsLocalGraphAuthoritative() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let stager = RecordingTOSStager(now: now)
    let client = RecordingLASClient(includesArtifacts: true)
    let checkpoints = OrchestratorCheckpointLedger()
    let configuration = lasAnalysisConfiguration(now: now, requestedMode: .lasDeep)
    let runtime = RetrievalAssembly.CloudAnalysisRuntime(
        makeLASClient: { _ in client },
        makeTOSStager: { _ in stager },
        sleep: { _ in },
        now: { now }
    )
    let enricher = ConfiguredCloudAnalysisEnricher(configuration: configuration, runtime: runtime)
    let graph = try orchestratorGraph()
    let sourceURL = try orchestratorMediaFixture()
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let result = try await enricher.enrich(
        source: orchestratorSource(sourceURL),
        asset: graph.asset,
        graph: graph,
        resume: nil,
        checkpoint: { await checkpoints.append($0) }
    )

    #expect(await stager.newUploadCount == 1)
    #expect(await stager.cleanupCount == 1)
    #expect(await client.submittedContracts == [
        .videoStoryboard,
        .videoFineUnderstanding,
        .scriptGeneration,
        .enhancedASR,
    ])
    #expect(result.context.cloudMode == .cloudDeep)
    #expect(result.context.mediaUploaded)
    #expect(result.context.mediaBytesUploaded == graph.asset.fileSizeBytes)
    #expect(result.evidence.allSatisfy { evidence in
        graph.shots.contains { shot in
            min(shot.timeRange.endSeconds, evidence.timeRange.endSeconds)
                > max(shot.timeRange.startSeconds, evidence.timeRange.startSeconds)
        }
    })
    #expect(result.shotsNeedingReview == [ShotID(rawValue: "S001")])
    #expect(result.globalSummary?.contains("Grounded generated script") == true)
    #expect(result.evidence.contains(where: { $0.rawText?.contains("A verified provider scene") == true }))
    #expect(await checkpoints.values.count >= 6)
}

@Test func restartReusesStagedObjectAndAcknowledgedPaidJobs() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let stager = RecordingTOSStager(now: now)
    let interruptedClient = RecordingLASClient(failBeforeContract: .scriptGeneration)
    let firstCheckpoints = OrchestratorCheckpointLedger()
    let configuration = lasAnalysisConfiguration(now: now, requestedMode: .lasDeep)
    let first = ConfiguredCloudAnalysisEnricher(
        configuration: configuration,
        runtime: RetrievalAssembly.CloudAnalysisRuntime(
            makeLASClient: { _ in interruptedClient },
            makeTOSStager: { _ in stager },
            sleep: { _ in },
            now: { now }
        )
    )
    let graph = try orchestratorGraph()
    let sourceURL = try orchestratorMediaFixture()
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    await #expect(throws: VideoUnderstandingError.self) {
        try await first.enrich(
            source: orchestratorSource(sourceURL),
            asset: graph.asset,
            graph: graph,
            resume: nil,
            checkpoint: { await firstCheckpoints.append($0) }
        )
    }
    let resume = try #require(await firstCheckpoints.values.last)
    let restartedClient = RecordingLASClient()
    let restarted = ConfiguredCloudAnalysisEnricher(
        configuration: configuration,
        runtime: RetrievalAssembly.CloudAnalysisRuntime(
            makeLASClient: { _ in restartedClient },
            makeTOSStager: { _ in stager },
            sleep: { _ in },
            now: { now }
        )
    )

    _ = try await restarted.enrich(
        source: orchestratorSource(sourceURL),
        asset: graph.asset,
        graph: graph,
        resume: resume,
        checkpoint: { _ in }
    )

    #expect(await stager.newUploadCount == 1)
    #expect(await restartedClient.submittedContracts == [.scriptGeneration, .enhancedASR])
}

@Test func unknownSubmitAcknowledgementIsCheckpointedAndNeverAutomaticallyRetried() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let stager = RecordingTOSStager(now: now)
    let firstClient = RecordingLASClient(acknowledgementUnknownAt: .videoStoryboard)
    let checkpoints = OrchestratorCheckpointLedger()
    let configuration = lasAnalysisConfiguration(now: now, requestedMode: .lasDeep)
    let graph = try orchestratorGraph()
    let sourceURL = try orchestratorMediaFixture()
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let first = ConfiguredCloudAnalysisEnricher(
        configuration: configuration,
        runtime: CloudAnalysisRuntime(
            makeLASClient: { _ in firstClient },
            makeTOSStager: { _ in stager },
            sleep: { _ in },
            now: { now }
        )
    )

    await #expect(throws: VideoUnderstandingError.self) {
        try await first.enrich(
            source: orchestratorSource(sourceURL),
            asset: graph.asset,
            graph: graph,
            resume: nil,
            checkpoint: { await checkpoints.append($0) }
        )
    }
    let resume = try #require(await checkpoints.values.last)
    #expect(resume.state == "submit-ack-unknown-videoStoryboard")
    let restartedClient = RecordingLASClient()
    let restarted = ConfiguredCloudAnalysisEnricher(
        configuration: configuration,
        runtime: CloudAnalysisRuntime(
            makeLASClient: { _ in restartedClient },
            makeTOSStager: { _ in stager },
            sleep: { _ in },
            now: { now }
        )
    )

    await #expect(throws: VideoUnderstandingError.self) {
        try await restarted.enrich(
            source: orchestratorSource(sourceURL),
            asset: graph.asset,
            graph: graph,
            resume: resume,
            checkpoint: { _ in }
        )
    }

    #expect(await stager.newUploadCount == 1)
    #expect(await restartedClient.submitAttemptedContracts.isEmpty)
}

@Test func transientProviderSubmitFailureUsesBoundedRetry() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let client = RecordingLASClient(transientFailureCounts: [.videoStoryboard: 2])
    let graph = try orchestratorGraph()
    let sourceURL = try orchestratorMediaFixture()
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let enricher = ConfiguredCloudAnalysisEnricher(
        configuration: lasAnalysisConfiguration(now: now, requestedMode: .lasDeep),
        runtime: CloudAnalysisRuntime(
            makeLASClient: { _ in client },
            makeTOSStager: { _ in RecordingTOSStager(now: now) },
            sleep: { _ in },
            now: { now }
        )
    )

    _ = try await enricher.enrich(
        source: orchestratorSource(sourceURL),
        asset: graph.asset,
        graph: graph,
        resume: nil,
        checkpoint: { _ in }
    )

    let attempts = await client.submitAttemptedContracts
    #expect(attempts.filter { $0 == .videoStoryboard }.count == 3)
}

@Test func cancellationDuringMultipartStagingCleansCheckpointedObject() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let stager = RecordingTOSStager(now: now, cancelDuringStage: true)
    let checkpoints = OrchestratorCheckpointLedger()
    let graph = try orchestratorGraph()
    let sourceURL = try orchestratorMediaFixture()
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let enricher = ConfiguredCloudAnalysisEnricher(
        configuration: lasAnalysisConfiguration(now: now, requestedMode: .lasDeep),
        runtime: CloudAnalysisRuntime(
            makeLASClient: { _ in RecordingLASClient() },
            makeTOSStager: { _ in stager },
            sleep: { _ in },
            now: { now }
        )
    )

    await #expect(throws: CancellationError.self) {
        try await enricher.enrich(
            source: orchestratorSource(sourceURL),
            asset: graph.asset,
            graph: graph,
            resume: nil,
            checkpoint: { await checkpoints.append($0) }
        )
    }

    #expect(await stager.cleanupCount == 1)
    #expect(await checkpoints.values.last?.state == "cancelled-during-staging-clean")
}

@Test func arkStandardNeverStagesWholeVideo() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let stager = RecordingTOSStager(now: now)
    let client = RecordingLASClient()
    let enricher = ConfiguredCloudAnalysisEnricher(
        configuration: lasAnalysisConfiguration(now: now, requestedMode: .arkStandard),
        runtime: CloudAnalysisRuntime(
            makeLASClient: { _ in client },
            makeTOSStager: { _ in stager },
            sleep: { _ in },
            now: { now }
        )
    )
    let graph = try orchestratorGraph()
    let sourceURL = try orchestratorMediaFixture()
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let result = try await enricher.enrich(
        source: orchestratorSource(sourceURL),
        asset: graph.asset,
        graph: graph,
        resume: nil,
        checkpoint: { _ in }
    )

    #expect(result.context.cloudMode == .cloudStandard)
    #expect(!result.context.mediaUploaded)
    #expect(await stager.newUploadCount == 0)
    #expect(await client.submittedContracts.isEmpty)
}

@Test func hybridExposesOnlyLowConfidenceShotsForArkRefinement() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let stager = RecordingTOSStager(now: now)
    let client = RecordingLASClient()
    let enricher = ConfiguredCloudAnalysisEnricher(
        configuration: lasAnalysisConfiguration(now: now, requestedMode: .hybridMaximum),
        runtime: CloudAnalysisRuntime(
            makeLASClient: { _ in client },
            makeTOSStager: { _ in stager },
            sleep: { _ in },
            now: { now }
        )
    )
    let graph = try orchestratorGraph()
    let sourceURL = try orchestratorMediaFixture()
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let result = try await enricher.enrich(
        source: orchestratorSource(sourceURL),
        asset: graph.asset,
        graph: graph,
        resume: nil,
        checkpoint: { _ in }
    )

    #expect(result.context.refinementShotIDs == [ShotID(rawValue: "S001")])
    #expect(result.shotsNeedingReview == [ShotID(rawValue: "S001")])
}

@Test func normalRunBlocksUnprobedRolesWhileExplicitDiagnosticRecordsOnlyCompletedLiveContracts() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let sourceURL = try orchestratorMediaFixture()
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let graph = try orchestratorGraph()
    let blockedStager = RecordingTOSStager(now: now)
    let blocked = ConfiguredCloudAnalysisEnricher(
        configuration: lasAnalysisConfiguration(
            now: now,
            requestedMode: .lasDeep,
            capabilitySnapshots: []
        ),
        runtime: CloudAnalysisRuntime(
            makeLASClient: { _ in RecordingLASClient() },
            makeTOSStager: { _ in blockedStager },
            sleep: { _ in },
            now: { now }
        )
    )

    await #expect(throws: VideoUnderstandingError.self) {
        try await blocked.enrich(
            source: orchestratorSource(sourceURL),
            asset: graph.asset,
            graph: graph,
            resume: nil,
            checkpoint: { _ in }
        )
    }
    #expect(await blockedStager.newUploadCount == 0)

    let recorder = CapabilityRecorder()
    let diagnosticStager = RecordingTOSStager(now: now)
    let diagnostic = ConfiguredCloudAnalysisEnricher(
        configuration: lasAnalysisConfiguration(
            now: now,
            requestedMode: .lasDeep,
            capabilitySnapshots: [],
            capabilityRecorder: recorder
        ),
        runtime: CloudAnalysisRuntime(
            makeLASClient: { _ in RecordingLASClient() },
            makeTOSStager: { _ in diagnosticStager },
            sleep: { _ in },
            now: { now }
        ),
        allowsUnprobedDiagnostic: true
    )

    _ = try await diagnostic.enrich(
        source: orchestratorSource(sourceURL),
        asset: graph.asset,
        graph: graph,
        resume: nil,
        checkpoint: { _ in }
    )

    let recorded = recorder.snapshot()
    #expect(Set(recorded.map(\.role)) == CloudProviderRole.lasDeepRoles)
    #expect(recorded.allSatisfy { $0.probeLevel == .liveMedia })
    #expect(recorded.allSatisfy { $0.sanitizedEvidenceCode == "live-media-contract-completed" })
}

private func lasAnalysisConfiguration(
    now: Date,
    requestedMode: CloudVision.CloudAnalysisRequestedMode,
    capabilitySnapshots overrideSnapshots: [CloudRoleCapabilitySnapshot]? = nil,
    capabilityRecorder: CapabilityRecorder? = nil
) -> CloudAIResolver.AnalysisConfiguration {
    let requiredRoles: Set<CloudProviderRole> = switch requestedMode {
    case .local: []
    case .arkStandard: CloudProviderRole.arkStandardRoles
    case .lasDeep: CloudProviderRole.lasDeepRoles
    case .hybridMaximum: CloudProviderRole.lasDeepRoles.union(CloudProviderRole.arkStandardRoles)
    }
    let fingerprints = requiredRoles.reduce(into: [CloudProviderRole: String]()) {
        $0[$1] = "fingerprint-\($1.rawValue)"
    }
    let snapshots = requiredRoles.map { role in
        CloudRoleCapabilitySnapshot(
            role: role,
            providerKind: role.providerKind,
            profileID: "production-\(role.rawValue)",
            configurationFingerprint: fingerprints[role]!,
            credentialScheme: role == .mediaStaging ? .temporarySTS : .apiKey,
            credentialReferenceID: "credential-\(role.rawValue)",
            probeLevel: .liveMedia,
            status: .available,
            observedCapabilities: [role.rawValue],
            acceptedMediaKinds: role == .lasEnhancedASR ? [.tosObject, .video] : [.tosObject],
            limits: CloudObservedLimits(maximumBytes: 100, maximumDurationSeconds: 100),
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
    return CloudAIResolver.AnalysisConfiguration(
        requestedMode: requestedMode,
        expectedFingerprints: fingerprints,
        capabilitySnapshots: overrideSnapshots ?? snapshots,
        arkConfigured: requiredRoles.isSuperset(of: CloudProviderRole.arkStandardRoles),
        region: .cnBeijing,
        lasAPIKey: "las-secret",
        stagingConfiguration: TOSMediaStagingConfiguration(
            region: .cnBeijing,
            bucket: "fixture-bucket",
            objectPrefix: "engram/runs/",
            partSizeBytes: 5
        ),
        stagingCredentials: TOSTemporaryCredentials(
            accessKeyID: "sts-access",
            secretAccessKey: "sts-secret",
            securityToken: "sts-token",
            expiresAt: now.addingTimeInterval(3_600)
        ),
        maximumUploadBytes: 100,
        requestConsent: { prompt in
            CloudRunConsentReceipt(
                runID: prompt.runID,
                sourceFingerprint: prompt.sourceFingerprint,
                planHash: prompt.planHash,
                acceptedAt: now,
                maximumBytes: prompt.byteCount,
                maximumDurationSeconds: prompt.durationSeconds,
                costAcceptance: .unknownMayCharge
            )
        },
        invalidateCapability: { _, _ in },
        recordCapability: { capabilityRecorder?.record($0) }
    )
}

private final class CapabilityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CloudRoleCapabilitySnapshot] = []

    func record(_ value: CloudRoleCapabilitySnapshot) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [CloudRoleCapabilitySnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

actor RecordingTOSStager: TOSMediaStaging {
    private let now: Date
    private let cancelDuringStage: Bool
    private(set) var newUploadCount = 0
    private(set) var cleanupCount = 0

    init(now: Date, cancelDuringStage: Bool = false) {
        self.now = now
        self.cancelDuringStage = cancelDuringStage
    }

    func stage(
        fileURL: URL,
        sourceFingerprint: String,
        byteCount: Int64,
        consent: CloudRunConsentReceipt,
        credentials: TOSTemporaryCredentials,
        checkpoint: TOSUploadCheckpoint?,
        persistCheckpoint: @Sendable (TOSUploadCheckpoint) async throws -> Void
    ) async throws -> TOSStagingResult {
        if checkpoint == nil { newUploadCount += 1 }
        let value = checkpoint ?? TOSUploadCheckpoint(
            sourceFingerprint: sourceFingerprint,
            objectKey: "engram/runs/\(sourceFingerprint).mov",
            uploadID: "upload-1",
            byteCount: byteCount,
            parts: [TOSUploadedPart(number: 1, eTag: "etag-1")],
            isCompleted: true,
            isVerified: true,
            isProviderReadable: true,
            cleanupState: .pending,
            expiresAt: now.addingTimeInterval(86_400)
        )
        try await persistCheckpoint(value)
        if cancelDuringStage { throw CancellationError() }
        return TOSStagingResult(
            object: TOSStagedObject(
                bucket: "fixture-bucket",
                objectKey: value.objectKey,
                tosURL: "tos://fixture-bucket/\(value.objectKey)",
                byteCount: byteCount,
                expiresAt: value.expiresAt
            ),
            checkpoint: value
        )
    }

    func cleanup(
        _ checkpoint: TOSUploadCheckpoint,
        credentials: TOSTemporaryCredentials
    ) async -> TOSUploadCheckpoint {
        cleanupCount += 1
        return TOSUploadCheckpoint(
            sourceFingerprint: checkpoint.sourceFingerprint,
            objectKey: checkpoint.objectKey,
            uploadID: checkpoint.uploadID,
            byteCount: checkpoint.byteCount,
            parts: checkpoint.parts,
            isCompleted: checkpoint.isCompleted,
            isVerified: checkpoint.isVerified,
            isProviderReadable: checkpoint.isProviderReadable,
            cleanupState: .deleted,
            expiresAt: checkpoint.expiresAt
        )
    }

    func readArtifact(
        at tosURL: String,
        maximumBytes: Int,
        credentials: TOSTemporaryCredentials
    ) async throws -> Data {
        if tosURL.hasSuffix("segments.json") {
            return Data(#"{"segments":[{"start_time":0,"end_time":1,"scene_description":"A verified provider scene."}]}"#.utf8)
        }
        if tosURL.hasSuffix("episode-1.md") {
            return Data(#"{"shots":[{"start-seconds":0,"start_seconds":99,"end_seconds":1,"purpose":"Grounded generated script one","subject_action":"LAS cloud action one","dialogue_or_vo":"LAS cloud dialogue one","on_screen_copy":"LAS cloud copy one","production_notes":"LAS cloud note one"},{"start_seconds":1,"end_seconds":2,"target_duration_ms":800,"purpose":"Grounded generated script two","subject_action":"LAS cloud action two","dialogue_or_vo":"LAS cloud dialogue two","on_screen_copy":"LAS cloud copy two","production_notes":"LAS cloud note two"}]}"#.utf8)
        }
        return Data(#"{"character":"A verified character"}"#.utf8)
    }

    func listArtifacts(
        at tosPrefix: String,
        maximumCount: Int,
        credentials: TOSTemporaryCredentials
    ) async throws -> [String] {
        ["tos://fixture-bucket/engram/runs/output/scripts/episode-1.md"]
    }
}

actor RecordingLASClient: LASOperatorClient {
    private(set) var submittedContracts: [LASOperatorContract] = []
    private(set) var submitAttemptedContracts: [LASOperatorContract] = []
    let failBeforeContract: LASOperatorContract?
    let includesArtifacts: Bool
    let acknowledgementUnknownAt: LASOperatorContract?
    var transientFailureCounts: [LASOperatorContract: Int]

    init(
        failBeforeContract: LASOperatorContract? = nil,
        includesArtifacts: Bool = false,
        acknowledgementUnknownAt: LASOperatorContract? = nil,
        transientFailureCounts: [LASOperatorContract: Int] = [:]
    ) {
        self.failBeforeContract = failBeforeContract
        self.includesArtifacts = includesArtifacts
        self.acknowledgementUnknownAt = acknowledgementUnknownAt
        self.transientFailureCounts = transientFailureCounts
    }

    func submit(
        _ invocation: LASOperatorInvocation,
        apiKey: String
    ) async throws -> LASOperatorTaskReceipt {
        submitAttemptedContracts.append(invocation.contract)
        if invocation.contract == acknowledgementUnknownAt {
            throw LASOperatorTransportError.submissionAcknowledgementUnknown
        }
        if let remaining = transientFailureCounts[invocation.contract], remaining > 0 {
            transientFailureCounts[invocation.contract] = remaining - 1
            throw LASOperatorTransportError.providerUnavailable(503)
        }
        if invocation.contract == failBeforeContract {
            throw LASOperatorTransportError.providerUnavailable(503)
        }
        submittedContracts.append(invocation.contract)
        return receipt(contract: invocation.contract)
    }

    func poll(
        contract: LASOperatorContract,
        taskID: String,
        apiKey: String
    ) async throws -> LASOperatorTaskReceipt {
        receipt(contract: contract)
    }

    private func receipt(contract: LASOperatorContract) -> LASOperatorTaskReceipt {
        let observations: [CloudTimelineObservation] = switch contract {
        case .videoFineUnderstanding: [CloudTimelineObservation(
            id: "fine-1", startSeconds: 0, endSeconds: 1,
            text: "A low-confidence entrance.", confidence: 0.4, kind: .visual
        )]
        case .enhancedASR: [CloudTimelineObservation(
            id: "asr-1", startSeconds: 1.1, endSeconds: 1.8,
            text: "A spoken line.", confidence: 1, kind: .transcript
        )]
        default: []
        }
        let artifacts: [LASOperatorArtifact] = if includesArtifacts {
            switch contract {
            case .videoStoryboard: [
                LASOperatorArtifact(
                    kind: .storyboardSegments,
                    tosURL: "tos://fixture-bucket/engram/runs/output/segments.json"
                )!,
                LASOperatorArtifact(
                    kind: .storyboardCharacters,
                    tosURL: "tos://fixture-bucket/engram/runs/output/characters.json"
                )!,
            ]
            case .scriptGeneration: [
                LASOperatorArtifact(
                    kind: .generatedCharacters,
                    tosURL: "tos://fixture-bucket/engram/runs/output/final-characters.json"
                )!,
                LASOperatorArtifact(
                    kind: .generatedScripts,
                    tosURL: "tos://fixture-bucket/engram/runs/output/scripts",
                    isPrefix: true
                )!,
            ]
            default: []
            }
        } else { [] }
        return LASOperatorTaskReceipt(
            operatorID: contract.operatorID,
            taskID: "task-\(contract.rawValue)",
            state: .completed,
            businessCode: "0",
            requestID: nil,
            observations: observations,
            artifacts: artifacts,
            usage: CloudProviderUsage(requestCount: 1),
            sanitizedError: nil
        )
    }
}

private actor OrchestratorCheckpointLedger {
    private(set) var values: [CloudVideoJobCheckpoint] = []
    func append(_ value: CloudVideoJobCheckpoint) { values.append(value) }
}

private func orchestratorMediaFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("orchestrator-\(UUID().uuidString).mov")
    try Data([1, 2, 3]).write(to: url)
    return url
}

private func orchestratorSource(_ url: URL) -> VideoSource {
    VideoSource(
        id: "fixture",
        localFileURL: url,
        importedAt: Date(timeIntervalSince1970: 1),
        durationSeconds: 2
    )
}

private func orchestratorGraph() throws -> ShotGraph {
    let asset = VideoAssetDescriptor(
        sourceID: "fixture", durationSeconds: 2, nominalFrameRate: 30, frameCount: 60,
        width: 720, height: 1280, timescale: 600, codec: "fixture", hasAudio: true,
        fileSizeBytes: 3, fingerprint: SourceFingerprint(value: "fixture-fingerprint")
    )
    return try ShotGraph(asset: asset, shots: [
        ShotSegment(
            id: ShotID(rawValue: "S001"),
            timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 1),
            frameRange: FrameRange(startFrame: 0, endFrameExclusive: 30),
            transitionIn: .start, transitionOut: .cut, boundaryConfidence: 1,
            detectorEvidenceIDs: ["detector:S001"]
        ),
        ShotSegment(
            id: ShotID(rawValue: "S002"),
            timeRange: MediaTimeRange(startSeconds: 1, endSeconds: 2),
            frameRange: FrameRange(startFrame: 30, endFrameExclusive: 60),
            transitionIn: .cut, transitionOut: .end, boundaryConfidence: 1,
            detectorEvidenceIDs: ["detector:S002"]
        ),
    ])
}
