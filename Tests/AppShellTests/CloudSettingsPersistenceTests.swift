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
