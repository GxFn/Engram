import ClipDigest
import CloudVision
import Foundation
import ScriptCore
import StoryboardCore
import VideoUnderstanding

/// Leaf transport seams only. The production planner, role order, restart state, alignment and
/// authoritative local graph remain assembled by AppShell in both production and tests.
public struct CloudAnalysisRuntime: Sendable {
    let makeLASClient: @Sendable (CloudVision.LASServiceRegion) -> any LASOperatorClient
    let makeTOSStager: @Sendable (TOSMediaStagingConfiguration) -> any TOSMediaStaging
    let sleep: @Sendable (Duration) async throws -> Void
    let now: @Sendable () -> Date

    public init(
        makeLASClient: @escaping @Sendable (CloudVision.LASServiceRegion) -> any LASOperatorClient,
        makeTOSStager: @escaping @Sendable (TOSMediaStagingConfiguration) -> any TOSMediaStaging,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date
    ) {
        self.makeLASClient = makeLASClient
        self.makeTOSStager = makeTOSStager
        self.sleep = sleep
        self.now = now
    }

    public static let live = Self(
        makeLASClient: { URLSessionLASOperatorClient(region: $0) },
        makeTOSStager: { URLSessionTOSMediaStager(configuration: $0) },
        sleep: { try await Task.sleep(for: $0) },
        now: Date.init
    )
}

extension RetrievalAssembly {
    typealias CloudAnalysisRuntime = AppShell.CloudAnalysisRuntime
}

struct ConfiguredCloudAnalysisEnricher: CloudStoryboardEnriching {
    private static let providerID = "volcengine-las-multirole"

    let configuration: CloudAIResolver.AnalysisConfiguration
    let runtime: CloudAnalysisRuntime
    let allowsUnprobedDiagnostic: Bool

    init(
        configuration: CloudAIResolver.AnalysisConfiguration,
        runtime: CloudAnalysisRuntime = .live,
        allowsUnprobedDiagnostic: Bool = false
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.allowsUnprobedDiagnostic = allowsUnprobedDiagnostic
    }

    func enrich(
        source: VideoSource,
        asset: VideoAssetDescriptor,
        graph: ShotGraph,
        resume: CloudVideoJobCheckpoint?,
        checkpoint persistCheckpoint: @Sendable (CloudVideoJobCheckpoint) async throws -> Void
    ) async throws -> CloudStoryboardEnrichment {
        switch configuration.requestedMode {
        case .local:
            return .local
        case .arkStandard:
            let decision = CloudAnalysisPlanner.resolve(
                requested: .arkStandard,
                snapshots: configuration.capabilitySnapshots,
                expectedFingerprints: configuration.expectedFingerprints,
                consent: nil,
                now: runtime.now()
            )
            guard configuration.arkConfigured, decision.effectiveMode == .arkStandard else {
                let unavailable = roleList(decision.missingRoles + decision.staleRoles)
                throw blocked("Ark Standard requires fresh arkText and arkFrame capability evidence: \(unavailable)")
            }
            return CloudStoryboardEnrichment(context: StoryboardExecutionContext(
                requestedCloudMode: .cloudStandard,
                cloudMode: .cloudStandard,
                mediaUploaded: false,
                analysisRequestedMode: CloudAnalysisRequestedMode.arkStandard.rawValue,
                analysisEffectiveMode: CloudAnalysisEffectiveMode.arkStandard.rawValue,
                providerRoles: CloudProviderRole.arkStandardRoles.sorted().map(\.rawValue),
                cleanupState: "not-applicable"
            ))
        case .lasDeep, .hybridMaximum:
            break
        }

        var restored = CloudAnalysisResumeState()
        if let resume,
           resume.providerID == Self.providerID,
           resume.sourceFingerprint == asset.fingerprint.value,
           let data = resume.opaqueState,
           let decoded = try? JSONDecoder().decode(CloudAnalysisResumeState.self, from: data) {
            restored = decoded
        }
        let state = CloudAnalysisStateBox(restored)
        let preflight = CloudAnalysisPlanner.resolve(
            requested: configuration.requestedMode,
            snapshots: configuration.capabilitySnapshots,
            expectedFingerprints: configuration.expectedFingerprints,
            consent: await state.snapshot().consent,
            now: runtime.now()
        )
        let unavailableRoles = Set(preflight.missingRoles + preflight.staleRoles)
        let isExplicitLASDiagnostic = allowsUnprobedDiagnostic
            && configuration.requestedMode == .lasDeep
            && !unavailableRoles.isEmpty
            && unavailableRoles.isSubset(of: CloudProviderRole.lasDeepRoles)
        if preflight.effectiveMode == .awaitingCapabilityProbe && !isExplicitLASDiagnostic {
            throw blocked("capability evidence expired: \(roleList(preflight.staleRoles))")
        }
        if preflight.effectiveMode == .requiresUserChoice && !isExplicitLASDiagnostic {
            let choices = preflight.allowedAlternatives.map(\.rawValue).joined(separator: ",")
            throw blocked("missing cloud roles: \(roleList(preflight.missingRoles)); choose explicitly: \(choices)")
        }

        let consent: CloudRunConsentReceipt
        if let restoredConsent = await state.snapshot().consent,
           valid(restoredConsent, for: asset, planHash: preflight.planHash) {
            consent = restoredConsent
        } else {
            let prompt = CloudRunConsentPrompt(
                runID: UUID().uuidString,
                sourceFingerprint: asset.fingerprint.value,
                planHash: preflight.planHash,
                byteCount: asset.fileSizeBytes,
                durationSeconds: asset.durationSeconds,
                costAcceptance: .unknownMayCharge
            )
            guard let accepted = await configuration.requestConsent(prompt),
                  valid(accepted, for: asset, planHash: preflight.planHash)
            else {
                throw blocked("LAS upload awaits one-run consent; cost is unknown and may be charged")
            }
            consent = accepted
            await state.setConsent(accepted)
            try await persist(
                state: state,
                sourceFingerprint: asset.fingerprint.value,
                phase: "consented",
                fallbackIdentity: "consent-\(accepted.runID)",
                checkpoint: persistCheckpoint
            )
        }
        let decision = CloudAnalysisPlanner.resolve(
            requested: configuration.requestedMode,
            snapshots: configuration.capabilitySnapshots,
            expectedFingerprints: configuration.expectedFingerprints,
            consent: consent,
            now: runtime.now()
        )
        if !isExplicitLASDiagnostic {
            guard decision.mediaUploadAllowed,
                  decision.effectiveMode == .lasDeep || decision.effectiveMode == .lasArkRefine
            else { throw blocked("cloud plan is not executable: \(decision.effectiveMode.rawValue)") }
        }
        guard let lasAPIKey = configuration.lasAPIKey, !lasAPIKey.isEmpty else {
            throw blocked("missing cloud role: las API key")
        }
        guard let stagingConfiguration = configuration.stagingConfiguration,
              let stagingCredentials = configuration.stagingCredentials
        else { throw blocked("missing cloud role: mediaStaging") }
        guard asset.fileSizeBytes <= configuration.maximumUploadBytes else {
            throw blocked("asset exceeds the configured one-run LAS upload limit")
        }

        let stager = runtime.makeTOSStager(stagingConfiguration)
        let existingStaging = await state.snapshot().staging
        let staged: TOSStagingResult
        do {
            staged = try await stager.stage(
                fileURL: source.localFileURL,
                sourceFingerprint: asset.fingerprint.value,
                byteCount: asset.fileSizeBytes,
                consent: consent,
                credentials: stagingCredentials,
                checkpoint: existingStaging,
                persistCheckpoint: { value in
                    await state.setStaging(value)
                    try await persist(
                        state: state,
                        sourceFingerprint: asset.fingerprint.value,
                        phase: "staging",
                        fallbackIdentity: value.uploadID,
                        checkpoint: persistCheckpoint
                    )
                }
            )
        } catch is CancellationError {
            await cleanupAndPersist(
                stager: stager,
                credentials: stagingCredentials,
                state: state,
                sourceFingerprint: asset.fingerprint.value,
                phasePrefix: "cancelled-during-staging",
                fallbackIdentity: "staging-cancelled",
                checkpoint: persistCheckpoint
            )
            throw CancellationError()
        } catch TOSMediaStagingError.authenticationRejected {
            await cleanupAndPersist(
                stager: stager,
                credentials: stagingCredentials,
                state: state,
                sourceFingerprint: asset.fingerprint.value,
                phasePrefix: "staging-auth-failed",
                fallbackIdentity: "staging-auth-failed",
                error: "media-staging-authentication-rejected",
                checkpoint: persistCheckpoint
            )
            configuration.invalidateCapability(.mediaStaging, 403)
            throw blocked("mediaStaging authentication rejected; capability invalidated")
        } catch {
            throw blocked("media staging is checkpointed for review: \(sanitize(error))")
        }
        await state.setStaging(staged.checkpoint)
        recordCapability(role: .mediaStaging)

        let client = runtime.makeLASClient(configuration.region)
        let outputPath = "tos://\(staged.object.bucket)/\(stagingConfiguration.objectPrefix)output/\(consent.runID)/"
        let invocations: [LASOperatorInvocation] = [
            .videoStoryboard(videoTOSURL: staged.object.tosURL, outputTOSPath: outputPath),
            .fineUnderstanding(
                videoTOSURL: staged.object.tosURL,
                query: "Return evidence-grounded events in time order with timestamps; never invent shot boundaries."
            ),
            .scriptGeneration(videoTOSURLs: [staged.object.tosURL], outputTOSPath: outputPath),
            .enhancedASR(
                audioTOSURL: staged.object.tosURL,
                format: source.localFileURL.pathExtension.lowercased().nilIfEmpty ?? "mp4"
            ),
        ]

        do {
            for invocation in invocations {
                try Task.checkCancellation()
                let contractKey = invocation.contract.rawValue
                let currentState = await state.snapshot()
                if currentState.uncertainSubmitContracts?.contains(contractKey) == true {
                    throw blocked("\(invocation.contract.role.rawValue) submit acknowledgement is unknown; user review is required before any paid resubmission")
                }
                var receipt = currentState.receipts[contractKey]
                if receipt == nil {
                    do {
                        receipt = try await submitWithBoundedRetry(
                            client: client,
                            invocation: invocation,
                            apiKey: lasAPIKey
                        )
                    } catch LASOperatorTransportError.authenticationRejected {
                        configuration.invalidateCapability(invocation.contract.role, 403)
                        throw LASOperatorTransportError.authenticationRejected
                    } catch LASOperatorTransportError.submissionAcknowledgementUnknown {
                        await state.markSubmitAcknowledgementUnknown(contract: invocation.contract)
                        try await persist(
                            state: state,
                            sourceFingerprint: asset.fingerprint.value,
                            phase: "submit-ack-unknown-\(contractKey)",
                            fallbackIdentity: "ack-unknown-\(contractKey)",
                            error: "submission-acknowledgement-unknown",
                            checkpoint: persistCheckpoint
                        )
                        throw blocked("\(invocation.contract.role.rawValue) submit acknowledgement is unknown; user review is required before any paid resubmission")
                    }
                    if let receipt {
                        await state.setReceipt(receipt, contract: invocation.contract)
                        try await persist(
                            state: state,
                            sourceFingerprint: asset.fingerprint.value,
                            phase: "submitted-\(invocation.contract.rawValue)",
                            fallbackIdentity: receipt.taskID,
                            checkpoint: persistCheckpoint
                        )
                    }
                }
                guard var current = receipt else {
                    throw LASOperatorTransportError.invalidResponse("submit-receipt-missing")
                }
                var polls = 0
                while current.state == .pending || current.state == .running {
                    guard polls < 60 else {
                        throw LASOperatorTransportError.invalidResponse("poll-limit-exceeded")
                    }
                    try await runtime.sleep(.seconds(min(8, 1 << min(polls, 3))))
                    current = try await pollWithBoundedRetry(
                        client: client,
                        contract: invocation.contract,
                        taskID: current.taskID,
                        apiKey: lasAPIKey
                    )
                    await state.setReceipt(current, contract: invocation.contract)
                    try await persist(
                        state: state,
                        sourceFingerprint: asset.fingerprint.value,
                        phase: "polled-\(invocation.contract.rawValue)",
                        fallbackIdentity: current.taskID,
                        checkpoint: persistCheckpoint
                    )
                    polls += 1
                }
                guard current.state == .completed, current.businessCode == "0" else {
                    let cleaned = await stager.cleanup(staged.checkpoint, credentials: stagingCredentials)
                    await state.setStaging(cleaned)
                    try? await persist(
                        state: state,
                        sourceFingerprint: asset.fingerprint.value,
                        phase: "terminal-failure",
                        fallbackIdentity: current.taskID,
                        error: current.sanitizedError,
                        checkpoint: persistCheckpoint
                    )
                    throw blocked("\(invocation.contract.role.rawValue) ended \(current.state.rawValue): \(current.sanitizedError ?? "provider-business-failure")")
                }
                recordCapability(role: invocation.contract.role)
            }
        } catch is CancellationError {
            await cleanupAndPersist(
                stager: stager,
                credentials: stagingCredentials,
                state: state,
                sourceFingerprint: asset.fingerprint.value,
                phasePrefix: "cancelled",
                fallbackIdentity: staged.checkpoint.uploadID,
                checkpoint: persistCheckpoint
            )
            throw CancellationError()
        } catch LASOperatorTransportError.authenticationRejected {
            await cleanupAndPersist(
                stager: stager,
                credentials: stagingCredentials,
                state: state,
                sourceFingerprint: asset.fingerprint.value,
                phasePrefix: "provider-auth-failed",
                fallbackIdentity: staged.checkpoint.uploadID,
                error: "provider-authentication-rejected",
                checkpoint: persistCheckpoint
            )
            throw blocked("LAS authentication rejected; capability invalidated")
        } catch let error as VideoUnderstandingError {
            throw error
        } catch {
            // Acknowledged jobs and the completed staged object remain checkpointed. Retrying from
            // this state polls/reuses them and never performs another paid submit.
            throw blocked("LAS execution is checkpointed for resume: \(sanitize(error))")
        }

        let receipts = await state.snapshot().receipts.values
        let consumedArtifacts: ConsumedLASArtifacts
        do {
            consumedArtifacts = try await consumeArtifacts(
                receipts.flatMap(\.artifacts),
                stager: stager,
                credentials: stagingCredentials,
                asset: asset
            )
        } catch is CancellationError {
            await cleanupAndPersist(
                stager: stager,
                credentials: stagingCredentials,
                state: state,
                sourceFingerprint: asset.fingerprint.value,
                phasePrefix: "cancelled-during-artifact-read",
                fallbackIdentity: staged.checkpoint.uploadID,
                checkpoint: persistCheckpoint
            )
            throw CancellationError()
        } catch TOSMediaStagingError.authenticationRejected {
            await cleanupAndPersist(
                stager: stager,
                credentials: stagingCredentials,
                state: state,
                sourceFingerprint: asset.fingerprint.value,
                phasePrefix: "artifact-auth-failed",
                fallbackIdentity: staged.checkpoint.uploadID,
                error: "result-artifact-authentication-rejected",
                checkpoint: persistCheckpoint
            )
            configuration.invalidateCapability(.mediaStaging, 403)
            throw blocked("result artifact authentication rejected; mediaStaging capability invalidated")
        } catch {
            await cleanupAndPersist(
                stager: stager,
                credentials: stagingCredentials,
                state: state,
                sourceFingerprint: asset.fingerprint.value,
                phasePrefix: "artifact-consumption-failed",
                fallbackIdentity: staged.checkpoint.uploadID,
                error: sanitize(error),
                checkpoint: persistCheckpoint
            )
            throw blocked("LAS result artifacts are not safely consumable: \(sanitize(error))")
        }
        let observations = receipts.flatMap(\.observations) + consumedArtifacts.observations
        let alignment = CloudTimelineAligner.align(observations, to: graph)
        let review = CloudRefinementPlanner.plan(alignment).shotIDs
        let refinementIDs = !isExplicitLASDiagnostic && decision.arkRefinementAllowed ? review : []
        let usage = receipts.reduce(CloudProviderUsage.zero) { partial, receipt in
            CloudProviderUsage(
                requestCount: partial.requestCount + receipt.usage.requestCount,
                inputTokens: partial.inputTokens + receipt.usage.inputTokens,
                outputTokens: partial.outputTokens + receipt.usage.outputTokens,
                mediaMilliseconds: partial.mediaMilliseconds + receipt.usage.mediaMilliseconds,
                estimatedUSD: Self.sum(partial.estimatedUSD, receipt.usage.estimatedUSD)
            )
        }
        let cleaned = await stager.cleanup(staged.checkpoint, credentials: stagingCredentials)
        await state.setStaging(cleaned)
        try await persist(
            state: state,
            sourceFingerprint: asset.fingerprint.value,
            phase: cleaned.cleanupState == .deleted ? "completed-clean" : "completed-cleanup-pending",
            fallbackIdentity: staged.checkpoint.uploadID,
            checkpoint: persistCheckpoint
        )
        let cleanupNote = cleaned.cleanupState == .deleted
            ? nil
            : "cloud result retained, but staged media cleanup is pending retry until the 24-hour TTL"
        let summaryParts = observations.filter { $0.kind == .visual }.map(\.text)
            + consumedArtifacts.summaries
        let summary = String(summaryParts.filter { !$0.isEmpty }.joined(separator: "\n").prefix(20_000)).nilIfEmpty
        return CloudStoryboardEnrichment(
            context: StoryboardExecutionContext(
                requestedCloudMode: .cloudDeep,
                cloudMode: .cloudDeep,
                mediaUploaded: true,
                mediaBytesUploaded: asset.fileSizeBytes,
                requestCount: usage.requestCount,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                mediaMilliseconds: usage.mediaMilliseconds,
                estimatedUSD: usage.estimatedUSD,
                refinementShotIDs: refinementIDs,
                degradationNote: cleanupNote,
                analysisRequestedMode: configuration.requestedMode.rawValue,
                analysisEffectiveMode: isExplicitLASDiagnostic
                    ? CloudAnalysisEffectiveMode.lasDeep.rawValue
                    : decision.effectiveMode.rawValue,
                providerRoles: ([CloudProviderRole.mediaStaging]
                    + invocations.map { $0.contract.role }
                    + (refinementIDs.isEmpty ? [] : Array(CloudProviderRole.arkStandardRoles).sorted()))
                    .map(\.rawValue),
                cleanupState: cleaned.cleanupState.rawValue
            ),
            evidence: alignment.items.map(\.evidence),
            shotsNeedingReview: review,
            globalSummary: summary
        )
    }

    private func pollWithBoundedRetry(
        client: any LASOperatorClient,
        contract: LASOperatorContract,
        taskID: String,
        apiKey: String
    ) async throws -> LASOperatorTaskReceipt {
        var retry = 0
        while true {
            do {
                return try await client.poll(contract: contract, taskID: taskID, apiKey: apiKey)
            } catch LASOperatorTransportError.authenticationRejected {
                configuration.invalidateCapability(contract.role, 403)
                throw LASOperatorTransportError.authenticationRejected
            } catch LASOperatorTransportError.rateLimited {
                guard retry < 3 else { throw LASOperatorTransportError.rateLimited }
            } catch LASOperatorTransportError.providerUnavailable(let status) {
                guard retry < 3 else { throw LASOperatorTransportError.providerUnavailable(status) }
            }
            try await runtime.sleep(.seconds(min(8, 1 << retry)))
            retry += 1
        }
    }

    private func submitWithBoundedRetry(
        client: any LASOperatorClient,
        invocation: LASOperatorInvocation,
        apiKey: String
    ) async throws -> LASOperatorTaskReceipt {
        var retry = 0
        while true {
            do {
                return try await client.submit(invocation, apiKey: apiKey)
            } catch LASOperatorTransportError.rateLimited {
                guard retry < 3 else { throw LASOperatorTransportError.rateLimited }
            } catch LASOperatorTransportError.providerUnavailable(let status) {
                guard retry < 3 else { throw LASOperatorTransportError.providerUnavailable(status) }
            }
            try await runtime.sleep(.seconds(min(8, 1 << retry)))
            retry += 1
        }
    }

    private func consumeArtifacts(
        _ artifacts: [LASOperatorArtifact],
        stager: any TOSMediaStaging,
        credentials: TOSTemporaryCredentials,
        asset: VideoAssetDescriptor
    ) async throws -> ConsumedLASArtifacts {
        var observations: [CloudTimelineObservation] = []
        var summaries: [String] = []
        var seen = Set<LASOperatorArtifact>()
        for artifact in artifacts where seen.insert(artifact).inserted {
            switch artifact.kind {
            case .storyboardSegments:
                let data = try await stager.readArtifact(
                    at: artifact.tosURL,
                    maximumBytes: 4 * 1_024 * 1_024,
                    credentials: credentials
                )
                observations.append(contentsOf: Self.timelineObservations(from: data, asset: asset))
            case .storyboardCharacters, .generatedCharacters:
                let data = try await stager.readArtifact(
                    at: artifact.tosURL,
                    maximumBytes: 1 * 1_024 * 1_024,
                    credentials: credentials
                )
                if let text = Self.artifactSummary(from: data, maximumCharacters: 4_000) {
                    summaries.append(text)
                }
            case .generatedScripts:
                let URLs = try await stager.listArtifacts(
                    at: artifact.tosURL,
                    maximumCount: 16,
                    credentials: credentials
                )
                let readable = URLs.filter { value in
                    let path = URLComponents(string: value)?.path.lowercased() ?? ""
                    return [".json", ".md", ".txt"].contains { path.hasSuffix($0) }
                }
                guard !readable.isEmpty else {
                    throw TOSMediaStagingError.invalidResponse("generated-script-artifacts-missing")
                }
                for URL in readable.prefix(8) {
                    let data = try await stager.readArtifact(
                        at: URL,
                        maximumBytes: 1 * 1_024 * 1_024,
                        credentials: credentials
                    )
                    if let text = Self.artifactSummary(from: data, maximumCharacters: 12_000) {
                        summaries.append(text)
                    }
                }
            }
        }
        return ConsumedLASArtifacts(observations: observations, summaries: summaries)
    }

    private static func timelineObservations(
        from data: Data,
        asset: VideoAssetDescriptor
    ) -> [CloudTimelineObservation] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var dictionaries: [[String: Any]] = []
        func collect(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                dictionaries.append(dictionary)
                dictionary.values.forEach(collect)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            }
        }
        collect(root)
        func timedValue(_ dictionary: [String: Any], keys: [String]) -> (Double, String)? {
            let canonical = Dictionary(uniqueKeysWithValues: dictionary.map {
                ($0.key.lowercased().replacingOccurrences(of: "-", with: "_"), $0.value)
            })
            for key in keys {
                let raw = canonical[key]
                let value: Double? = if let number = raw as? NSNumber {
                    number.doubleValue
                } else if let string = raw as? String {
                    Double(string)
                } else { nil }
                if let value, value.isFinite { return (value, key) }
            }
            return nil
        }
        func seconds(_ value: (Double, String), duration: Double) -> Double {
            let milliseconds = value.1.contains("ms") || value.0 > max(duration * 2, 300)
            return value.0 / (milliseconds ? 1_000 : 1)
        }
        var output: [CloudTimelineObservation] = []
        var identities = Set<String>()
        for dictionary in dictionaries {
            guard let rawStart = timedValue(dictionary, keys: [
                "start_seconds", "start_time_seconds", "start_time_ms", "start_ms", "start_time", "start",
            ]), let rawEnd = timedValue(dictionary, keys: [
                "end_seconds", "end_time_seconds", "end_time_ms", "end_ms", "end_time", "end",
            ]) else { continue }
            let start = min(asset.durationSeconds, max(0, seconds(rawStart, duration: asset.durationSeconds)))
            let end = min(asset.durationSeconds, max(start, seconds(rawEnd, duration: asset.durationSeconds)))
            guard end > start else { continue }
            let preferredKeys = ["scene_description", "description", "summary", "scene_name", "title", "content"]
            let text = preferredKeys.compactMap { dictionary[$0] as? String }.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? extractArtifactStrings(dictionary).prefix(3).joined(separator: " ")
            guard !text.isEmpty else { continue }
            let identity = "\(start)|\(end)|\(text)"
            guard identities.insert(identity).inserted else { continue }
            output.append(CloudTimelineObservation(
                id: "las-storyboard-artifact-\(output.count)",
                startSeconds: start,
                endSeconds: end,
                text: String(text.prefix(2_000)),
                confidence: 0.75,
                kind: .visual
            ))
            if output.count == 256 { break }
        }
        return output
    }

    private static func artifactSummary(from data: Data, maximumCharacters: Int) -> String? {
        if let root = try? JSONSerialization.jsonObject(with: data) {
            let text = extractArtifactStrings(root).joined(separator: "\n")
            return String(text.prefix(maximumCharacters)).nilIfEmpty
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return String(text.replacingOccurrences(of: "\0", with: "").prefix(maximumCharacters)).nilIfEmpty
    }

    private static func extractArtifactStrings(_ value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().flatMap { key -> [String] in
                let lowered = key.lowercased()
                guard !lowered.contains("url"), !lowered.contains("path"),
                      !lowered.contains("token"), !lowered.contains("secret")
                else { return [] }
                guard let child = dictionary[key] else { return [] }
                return extractArtifactStrings(child)
            }
        }
        if let array = value as? [Any] { return array.flatMap(extractArtifactStrings) }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("://") else { return [] }
            return [trimmed]
        }
        return []
    }

    private func recordCapability(role: CloudProviderRole) {
        guard let fingerprint = configuration.expectedFingerprints[role] else { return }
        let now = runtime.now()
        let isStaging = role == .mediaStaging
        let acceptedMedia: Set<CloudAcceptedMediaKind> = switch role {
        case .lasEnhancedASR: [.tosObject, .video, .audio]
        case .lasVideoStoryboard, .lasVideoFineUnderstanding, .lasScriptGeneration:
            [.tosObject, .video]
        case .mediaStaging: [.tosObject]
        case .arkText, .arkFrame: []
        }
        let profileID: String = if isStaging {
            "tos-\(configuration.region.rawValue)-temporary-sts"
        } else if let contract = Self.contract(for: role) {
            "las-\(configuration.region.rawValue)-\(contract.operatorID)"
        } else {
            "cloud-\(role.rawValue)"
        }
        let limits: CloudObservedLimits = switch role {
        case .mediaStaging:
            CloudObservedLimits(maximumBytes: configuration.maximumUploadBytes)
        case .lasVideoStoryboard:
            CloudObservedLimits(maximumDurationSeconds: 20 * 60)
        case .lasVideoFineUnderstanding:
            CloudObservedLimits(
                maximumBytes: 10 * 1_024 * 1_024 * 1_024,
                maximumDurationSeconds: 3 * 60 * 60
            )
        case .lasScriptGeneration, .lasEnhancedASR, .arkText, .arkFrame:
            CloudObservedLimits()
        }
        configuration.recordCapability(CloudRoleCapabilitySnapshot(
            role: role,
            providerKind: role.providerKind,
            profileID: profileID,
            configurationFingerprint: fingerprint,
            credentialScheme: isStaging ? .temporarySTS : .apiKey,
            credentialReferenceID: configuration.credentialReferenceIDs[role] ?? "",
            probeLevel: .liveMedia,
            status: .available,
            observedCapabilities: [role.rawValue],
            acceptedMediaKinds: acceptedMedia,
            limits: limits,
            supportsAsync: isStaging ? false : true,
            supportsIdempotency: isStaging ? true : false,
            supportsCancellation: isStaging ? true : false,
            reportsUsage: isStaging ? false : true,
            lastProbedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            officialContractRevision: "las-first-2026-07-13-v1",
            sanitizedEvidenceCode: "live-media-contract-completed"
        ))
    }

    private static func contract(for role: CloudProviderRole) -> LASOperatorContract? {
        LASOperatorContract.allCases.first { $0.role == role }
    }

    private func valid(
        _ consent: CloudRunConsentReceipt,
        for asset: VideoAssetDescriptor,
        planHash: String
    ) -> Bool {
        consent.sourceFingerprint == asset.fingerprint.value
            && consent.planHash == planHash
            && consent.maximumBytes >= asset.fileSizeBytes
            && consent.maximumDurationSeconds >= asset.durationSeconds
    }

    private func persist(
        state: CloudAnalysisStateBox,
        sourceFingerprint: String,
        phase: String,
        fallbackIdentity: String,
        error: String? = nil,
        checkpoint: @Sendable (CloudVideoJobCheckpoint) async throws -> Void
    ) async throws {
        let snapshot = await state.snapshot()
        let lastIdentity = snapshot.receipts.values.sorted { $0.taskID < $1.taskID }.last?.taskID
            ?? snapshot.staging?.uploadID
            ?? fallbackIdentity
        try await checkpoint(CloudVideoJobCheckpoint(
            providerID: Self.providerID,
            sourceFingerprint: sourceFingerprint,
            jobID: lastIdentity,
            state: phase,
            sanitizedError: error.map(CloudErrorSanitizer.sanitize),
            opaqueState: try JSONEncoder().encode(snapshot)
        ))
    }

    private func cleanupAndPersist(
        stager: any TOSMediaStaging,
        credentials: TOSTemporaryCredentials,
        state: CloudAnalysisStateBox,
        sourceFingerprint: String,
        phasePrefix: String,
        fallbackIdentity: String,
        error: String? = nil,
        checkpoint: @Sendable (CloudVideoJobCheckpoint) async throws -> Void
    ) async {
        guard let staged = await state.snapshot().staging else { return }
        let cleaned = await stager.cleanup(staged, credentials: credentials)
        await state.setStaging(cleaned)
        let suffix = cleaned.cleanupState == .deleted ? "clean" : "cleanup-pending"
        try? await persist(
            state: state,
            sourceFingerprint: sourceFingerprint,
            phase: "\(phasePrefix)-\(suffix)",
            fallbackIdentity: fallbackIdentity,
            error: error,
            checkpoint: checkpoint
        )
    }

    private func roleList(_ roles: [CloudProviderRole]) -> String {
        roles.map(\.rawValue).joined(separator: ",")
    }

    private func sanitize(_ error: Error) -> String {
        CloudErrorSanitizer.sanitize(String(describing: error))
    }

    private func blocked(_ message: String) -> VideoUnderstandingError {
        .visionUnavailable(CloudErrorSanitizer.sanitize(message))
    }

    private static func sum(_ lhs: Decimal?, _ rhs: Decimal?) -> Decimal? {
        switch (lhs, rhs) {
        case let (left?, right?): left + right
        case (.some, .none), (.none, .some), (.none, .none): nil
        }
    }
}

private struct ConsumedLASArtifacts: Sendable {
    let observations: [CloudTimelineObservation]
    let summaries: [String]
}

private struct CloudAnalysisResumeState: Codable, Hashable, Sendable {
    var consent: CloudRunConsentReceipt?
    var staging: TOSUploadCheckpoint?
    var receipts: [String: LASOperatorTaskReceipt] = [:]
    /// Optional keeps checkpoints written before this field backward-decodable.
    var uncertainSubmitContracts: Set<String>?
}

private actor CloudAnalysisStateBox {
    private var value: CloudAnalysisResumeState

    init(_ value: CloudAnalysisResumeState) { self.value = value }

    func snapshot() -> CloudAnalysisResumeState { value }
    func setConsent(_ consent: CloudRunConsentReceipt) { value.consent = consent }
    func setStaging(_ staging: TOSUploadCheckpoint) { value.staging = staging }
    func setReceipt(_ receipt: LASOperatorTaskReceipt, contract: LASOperatorContract) {
        value.receipts[contract.rawValue] = receipt
    }
    func markSubmitAcknowledgementUnknown(contract: LASOperatorContract) {
        value.uncertainSubmitContracts = (value.uncertainSubmitContracts ?? []).union([contract.rawValue])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
