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
    let client = RecordingLASClient()
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
        source: .file(sourceURL),
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
        evidence.shotIDs.allSatisfy { id in graph.shots.contains(where: { $0.id == id }) }
    })
    #expect(result.shotsNeedingReview == [ShotID(rawValue: "S001")])
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
            source: .file(sourceURL),
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
        source: .file(sourceURL),
        asset: graph.asset,
        graph: graph,
        resume: resume,
        checkpoint: { _ in }
    )

    #expect(await stager.newUploadCount == 1)
    #expect(await restartedClient.submittedContracts == [.scriptGeneration, .enhancedASR])
}

private func lasAnalysisConfiguration(
    now: Date,
    requestedMode: CloudVision.CloudAnalysisRequestedMode
) -> CloudAIResolver.AnalysisConfiguration {
    let fingerprints = CloudProviderRole.lasDeepRoles.reduce(into: [CloudProviderRole: String]()) {
        $0[$1] = "fingerprint-\($1.rawValue)"
    }
    let snapshots = CloudProviderRole.lasDeepRoles.map { role in
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
            acceptedMediaKinds: [.tosObject],
            limits: CloudObservedLimits(maximumBytes: 100, maximumDurationSeconds: 100),
            supportsAsync: true,
            supportsIdempotency: false,
            supportsCancellation: false,
            reportsUsage: true,
            lastProbedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            officialContractRevision: "las-first-2026-07-13-v1",
            sanitizedEvidenceCode: "mock-wire-only"
        )
    }
    return CloudAIResolver.AnalysisConfiguration(
        requestedMode: requestedMode,
        expectedFingerprints: fingerprints,
        capabilitySnapshots: snapshots,
        arkConfigured: false,
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
        invalidateCapability: { _, _ in }
    )
}

private actor RecordingTOSStager: TOSMediaStaging {
    private let now: Date
    private(set) var newUploadCount = 0
    private(set) var cleanupCount = 0

    init(now: Date) { self.now = now }

    func stage(
        fileURL: URL,
        sourceFingerprint: String,
        byteCount: Int64,
        consent: CloudRunConsentReceipt,
        credentials: TOSTemporaryCredentials,
        checkpoint: TOSUploadCheckpoint?,
        persistCheckpoint: @escaping @Sendable (TOSUploadCheckpoint) async throws -> Void
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
}

private actor RecordingLASClient: LASOperatorClient {
    private(set) var submittedContracts: [LASOperatorContract] = []
    let failBeforeContract: LASOperatorContract?

    init(failBeforeContract: LASOperatorContract? = nil) {
        self.failBeforeContract = failBeforeContract
    }

    func submit(
        _ invocation: LASOperatorInvocation,
        apiKey: String
    ) async throws -> LASOperatorTaskReceipt {
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
        return LASOperatorTaskReceipt(
            operatorID: contract.operatorID,
            taskID: "task-\(contract.rawValue)",
            state: .completed,
            businessCode: "0",
            requestID: nil,
            observations: observations,
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
