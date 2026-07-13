@testable import AppShell
import CloudVision
import Foundation
import SettingsFeature
import Testing

@Suite(.serialized)
struct CloudSettingsPersistenceTests {
    @Test
    func savedSettingsRoundTripIndependentArkLASAndStagingProfiles() throws {
        try withIsolatedCloudSettings { store, _ in
            let expiry = Date(timeIntervalSince1970: 9_000)
            let expected = VisionBackendSettings(
                requestedMode: .hybridMaximum,
                ark: ArkBackendSettings(
                    baseURL: "https://ark.cn-beijing.volces.com/api/v3",
                    textModelID: "ep-text",
                    frameModelID: "ep-frame"
                ),
                las: LASBackendSettings(
                    isEnabled: true,
                    region: .cnBeijing,
                    videoStoryboardOperatorID: "vs",
                    videoFineUnderstandingOperatorID: "vf",
                    scriptGenerationOperatorID: "vg",
                    enhancedASROperatorID: "sa"
                ),
                staging: TOSStagingSettings(
                    bucket: "personal-bucket",
                    objectPrefix: "engram/device-a/",
                    credentialReferenceID: "tos-sts-personal",
                    temporaryCredentialExpiresAt: expiry,
                    maximumUploadMegabytes: 800
                )
            )

            store.save(expected)
            try #require(store.setCredential(.arkAPIKey, value: "ark-secret"))
            try #require(store.setCredential(.lasAPIKey, value: "las-secret"))
            try #require(store.setCredential(.tosAccessKeyID, value: "sts-access"))
            try #require(store.setCredential(.tosSecretAccessKey, value: "sts-secret"))
            try #require(store.setCredential(.tosSecurityToken, value: "sts-token"))

            let loaded = store.load()
            #expect(loaded.requestedMode == .hybridMaximum)
            #expect(loaded.ark.textModelID == "ep-text")
            #expect(loaded.ark.frameModelID == "ep-frame")
            #expect(loaded.ark.hasAPIKey)
            #expect(loaded.las.videoStoryboardOperatorID == "vs")
            #expect(loaded.las.videoFineUnderstandingOperatorID == "vf")
            #expect(loaded.las.scriptGenerationOperatorID == "vg")
            #expect(loaded.las.enhancedASROperatorID == "sa")
            #expect(loaded.las.hasAPIKey)
            #expect(loaded.staging.bucket == "personal-bucket")
            #expect(loaded.staging.temporaryCredentialExpiresAt == expiry)
            #expect(loaded.staging.hasTemporaryCredentials)
        }
    }

    @Test
    func credentialRotationChangesOnlyTheOwningFingerprintsAndSecretsNeverEnterDefaults() throws {
        try withIsolatedCloudSettings { store, defaults in
            store.save(VisionBackendSettings(
                requestedMode: .hybridMaximum,
                ark: ArkBackendSettings(textModelID: "ep-text", frameModelID: "ep-frame"),
                las: LASBackendSettings(
                    isEnabled: true,
                    videoStoryboardOperatorID: "vs",
                    videoFineUnderstandingOperatorID: "vf",
                    scriptGenerationOperatorID: "vg",
                    enhancedASROperatorID: "sa"
                ),
                staging: TOSStagingSettings(
                    bucket: "bucket",
                    objectPrefix: "engram/private/",
                    credentialReferenceID: "sts-ref"
                )
            ))
            try #require(store.setCredential(.arkAPIKey, value: "ark-secret-one"))
            try #require(store.setCredential(.lasAPIKey, value: "las-secret-one"))
            try #require(store.setCredential(.tosAccessKeyID, value: "tos-access-one"))
            try #require(store.setCredential(.tosSecretAccessKey, value: "tos-secret-one"))
            try #require(store.setCredential(.tosSecurityToken, value: "tos-token-one"))
            let before = store.configurationFingerprints()

            try #require(store.setCredential(.lasAPIKey, value: "las-secret-two"))
            let after = store.configurationFingerprints()

            #expect(before[.arkText] == after[.arkText])
            #expect(before[.arkFrame] == after[.arkFrame])
            #expect(before[.mediaStaging] == after[.mediaStaging])
            #expect(before[.lasVideoStoryboard] != after[.lasVideoStoryboard])
            #expect(before[.lasVideoFineUnderstanding] != after[.lasVideoFineUnderstanding])
            #expect(before[.lasScriptGeneration] != after[.lasScriptGeneration])
            #expect(before[.lasEnhancedASR] != after[.lasEnhancedASR])

            let defaultsDescription = defaults.dictionaryRepresentation().description
            for forbidden in [
                "ark-secret-one", "las-secret-one", "las-secret-two",
                "tos-access-one", "tos-secret-one", "tos-token-one",
            ] {
                #expect(!defaultsDescription.contains(forbidden))
            }
            #expect(VisionBackendKeychainAccount.arkAPIKey != VisionBackendKeychainAccount.lasAPIKey)
            #expect(VisionBackendKeychainAccount.tosSecretAccessKey != VisionBackendKeychainAccount.tosSecurityToken)
        }
    }

    @Test
    func capabilitySnapshotsPersistSanitizedEvidenceAndInvalidateOnlyOwningRoles() throws {
        try withIsolatedCloudSettings { store, defaults in
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
                    objectPrefix: "engram/private/",
                    credentialReferenceID: "sts-ref",
                    temporaryCredentialExpiresAt: Date(timeIntervalSince1970: 100_000)
                )
            ))
            try #require(store.setCredential(.lasAPIKey, value: "las-secret"))
            try #require(store.setCredential(.tosAccessKeyID, value: "sts-access"))
            try #require(store.setCredential(.tosSecretAccessKey, value: "sts-secret"))
            try #require(store.setCredential(.tosSecurityToken, value: "sts-token"))
            let fingerprints = store.configurationFingerprints()
            let now = Date(timeIntervalSince1970: 10_000)
            for role in CloudProviderRole.lasDeepRoles {
                store.saveCapabilitySnapshot(capabilitySnapshot(
                    role: role,
                    fingerprint: try #require(fingerprints[role]),
                    now: now
                ))
            }

            #expect(store.loadCapabilitySnapshots().count == CloudProviderRole.lasDeepRoles.count)
            let persisted = defaults.data(forKey: CloudSettingsDefaultsKey.capabilitySnapshots)
            let encoded = String(decoding: try #require(persisted), as: UTF8.self)
            #expect(!encoded.contains("las-secret"))
            #expect(!encoded.contains("sts-token"))

            try #require(store.setCredential(.lasAPIKey, value: "las-secret-rotated"))

            let remaining = store.loadCapabilitySnapshots()
            #expect(remaining.map(\.role) == [.mediaStaging])
        }
    }
}

private func capabilitySnapshot(
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
        acceptedMediaKinds: [.tosObject],
        limits: CloudObservedLimits(maximumBytes: 1_000_000, maximumDurationSeconds: 3_600),
        supportsAsync: true,
        supportsIdempotency: false,
        supportsCancellation: false,
        reportsUsage: true,
        lastProbedAt: now,
        expiresAt: now.addingTimeInterval(86_400),
        officialContractRevision: "las-first-2026-07-13-v1",
        sanitizedEvidenceCode: "mock-live-media-contract"
    )
}

private func withIsolatedCloudSettings(
    _ body: (CloudSettingsStore, UserDefaults) throws -> Void
) throws {
    let suite = "CloudSettingsPersistenceTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let accounts = VisionBackendKeychainAccount.allAccounts
    let existing = Dictionary(uniqueKeysWithValues: accounts.map { ($0, KeychainStore.string(for: $0)) })
    defer {
        defaults.removePersistentDomain(forName: suite)
        for account in accounts { KeychainStore.set(existing[account] ?? nil, for: account) }
    }
    for account in accounts { KeychainStore.set(nil, for: account) }
    try body(CloudSettingsStore(defaults: defaults), defaults)
}
