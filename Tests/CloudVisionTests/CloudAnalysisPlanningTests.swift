@testable import CloudVision
import Foundation
import Testing

@Test func lasDeepDoesNotRequireArkWhenEveryLASRoleIsFreshAndConsentMatches() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let fingerprints = CloudProviderRole.lasDeepRoles.reduce(into: [CloudProviderRole: String]()) {
        $0[$1] = "fingerprint-\($1.rawValue)"
    }
    let snapshots = CloudProviderRole.lasDeepRoles.map {
        availableSnapshot(role: $0, fingerprint: fingerprints[$0]!, now: now)
    }
    let preflight = CloudAnalysisPlanner.resolve(
        requested: .lasDeep,
        snapshots: snapshots,
        expectedFingerprints: fingerprints,
        consent: nil,
        now: now
    )
    #expect(preflight.effectiveMode == .awaitingConsent)
    #expect(preflight.missingRoles.isEmpty)

    let consent = CloudRunConsentReceipt(
        runID: "run-1",
        sourceFingerprint: "asset-sha256",
        planHash: preflight.planHash,
        acceptedAt: now,
        maximumBytes: 50_000_000,
        maximumDurationSeconds: 1_200,
        costAcceptance: .unknownMayCharge
    )
    let decision = CloudAnalysisPlanner.resolve(
        requested: .lasDeep,
        snapshots: snapshots,
        expectedFingerprints: fingerprints,
        consent: consent,
        now: now
    )

    #expect(decision.effectiveMode == .lasDeep)
    #expect(decision.missingRoles.isEmpty)
    #expect(decision.mediaUploadAllowed)
    #expect(decision.arkRefinementAllowed == false)
}

@Test func missingLASRoleRequiresExplicitChoiceInsteadOfSilentDowngrade() {
    let now = Date(timeIntervalSince1970: 20_000)
    let roles = CloudProviderRole.lasDeepRoles.subtracting([.lasEnhancedASR])
    let fingerprints = CloudProviderRole.lasDeepRoles.reduce(into: [CloudProviderRole: String]()) {
        $0[$1] = "fingerprint-\($1.rawValue)"
    }
    let snapshots = roles.map { availableSnapshot(role: $0, fingerprint: fingerprints[$0]!, now: now) }

    let decision = CloudAnalysisPlanner.resolve(
        requested: .lasDeep,
        snapshots: snapshots,
        expectedFingerprints: fingerprints,
        consent: nil,
        now: now
    )

    #expect(decision.effectiveMode == .requiresUserChoice)
    #expect(decision.missingRoles == [.lasEnhancedASR])
    #expect(decision.mediaUploadAllowed == false)
    #expect(decision.allowedAlternatives == [.local, .cancel])
}

@Test func hybridAddsOnlyFreshArkRolesAfterLASDeepGate() {
    let now = Date(timeIntervalSince1970: 30_000)
    let required = CloudProviderRole.lasDeepRoles.union(CloudProviderRole.arkStandardRoles)
    let fingerprints = required.reduce(into: [CloudProviderRole: String]()) {
        $0[$1] = "fingerprint-\($1.rawValue)"
    }
    let snapshots = required.map { availableSnapshot(role: $0, fingerprint: fingerprints[$0]!, now: now) }
    let preflight = CloudAnalysisPlanner.resolve(
        requested: .hybridMaximum,
        snapshots: snapshots,
        expectedFingerprints: fingerprints,
        consent: nil,
        now: now
    )
    let consent = CloudRunConsentReceipt(
        runID: "run-hybrid",
        sourceFingerprint: "asset-hybrid",
        planHash: preflight.planHash,
        acceptedAt: now,
        maximumBytes: 100,
        maximumDurationSeconds: 10,
        costAcceptance: .knownEstimate(Decimal(string: "1.25")!)
    )
    let decision = CloudAnalysisPlanner.resolve(
        requested: .hybridMaximum,
        snapshots: snapshots,
        expectedFingerprints: fingerprints,
        consent: consent,
        now: now
    )

    #expect(decision.effectiveMode == .lasArkRefine)
    #expect(decision.arkRefinementAllowed)
}

@Test func capabilitySnapshotExpiresAt24HoursAndFingerprintMismatchInvalidatesIt() {
    let probed = Date(timeIntervalSince1970: 40_000)
    let snapshot = availableSnapshot(role: .lasVideoStoryboard, fingerprint: "config-a", now: probed)

    #expect(snapshot.authorizes(expectedFingerprint: "config-a", now: probed.addingTimeInterval(86_399)))
    #expect(!snapshot.authorizes(expectedFingerprint: "config-a", now: probed.addingTimeInterval(86_401)))
    #expect(!snapshot.authorizes(expectedFingerprint: "config-b", now: probed.addingTimeInterval(1)))
    #expect(snapshot.invalidated(forHTTPStatus: 401).status == .authFailed)
    #expect(snapshot.invalidated(forHTTPStatus: 403).status == .authFailed)
    #expect(snapshot.invalidated(forHTTPStatus: 429).status == .available)
}

private func availableSnapshot(
    role: CloudProviderRole,
    fingerprint: String,
    now: Date
) -> CloudRoleCapabilitySnapshot {
    CloudRoleCapabilitySnapshot(
        role: role,
        providerKind: role.providerKind,
        profileID: "profile-\(role.rawValue)",
        configurationFingerprint: fingerprint,
        credentialScheme: role == .mediaStaging ? .temporarySTS : .apiKey,
        credentialReferenceID: "credential-\(role.rawValue)",
        probeLevel: .liveMedia,
        status: .available,
        observedCapabilities: [role.rawValue],
        acceptedMediaKinds: [.tosObject],
        limits: CloudObservedLimits(maximumBytes: 1_000_000, maximumDurationSeconds: 3_600),
        supportsAsync: true,
        supportsIdempotency: true,
        supportsCancellation: false,
        reportsUsage: true,
        lastProbedAt: now,
        expiresAt: now.addingTimeInterval(86_400),
        officialContractRevision: "2026-07-13",
        sanitizedEvidenceCode: "mock-wire-contract-only"
    )
}
