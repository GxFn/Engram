import CloudVision
import Foundation
import SettingsFeature

enum CloudSettingsDefaultsKey {
    static let requestedMode = "cloud.requestedMode"
    static let arkBaseURL = "cloud.ark.baseURL"
    static let arkTextModelID = "cloud.ark.textModelID"
    static let arkFrameModelID = "cloud.ark.frameModelID"
    static let lasEnabled = "cloud.las.enabled"
    static let lasRegion = "cloud.las.region"
    static let lasVideoStoryboardOperatorID = "cloud.las.videoStoryboardOperatorID"
    static let lasVideoFineUnderstandingOperatorID = "cloud.las.videoFineUnderstandingOperatorID"
    static let lasScriptGenerationOperatorID = "cloud.las.scriptGenerationOperatorID"
    static let lasEnhancedASROperatorID = "cloud.las.enhancedASROperatorID"
    static let tosBucket = "cloud.tos.bucket"
    static let tosObjectPrefix = "cloud.tos.objectPrefix"
    static let tosCredentialReferenceID = "cloud.tos.credentialReferenceID"
    static let tosCredentialExpiresAt = "cloud.tos.credentialExpiresAt"
    static let tosMaximumUploadMegabytes = "cloud.tos.maximumUploadMegabytes"

    static func credentialRevision(_ slot: CloudCredentialSlot) -> String {
        "cloud.credentials.\(slot.rawValue).revision"
    }
}

/// Assembly-owned persistence for non-secret provider configuration and Keychain references.
/// A credential replacement increments a non-secret revision so only owning role snapshots and
/// dependency fingerprints become stale; no secret value participates in a persisted hash.
struct CloudSettingsStore: @unchecked Sendable {
    private static let contractRevision = "las-first-2026-07-13-v1"
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    func load() -> VisionBackendSettings {
        let requestedMode: SettingsFeature.CloudAnalysisRequestedMode
        if let raw = defaults?.string(forKey: CloudSettingsDefaultsKey.requestedMode),
           let value = SettingsFeature.CloudAnalysisRequestedMode(rawValue: raw) {
            requestedMode = value
        } else {
            let legacyKind = defaults?.string(forKey: VisionBackendDefaultsKey.kind) ?? "cloud"
            let legacyVideo = defaults?.string(forKey: VisionBackendDefaultsKey.cloudVideoMode) ?? "standard"
            requestedMode = if legacyKind == "onDevice" { .local }
                else if legacyVideo == "deep" { .lasDeep }
                else { .arkStandard }
        }

        let ark = ArkBackendSettings(
            baseURL: defaults?.string(forKey: CloudSettingsDefaultsKey.arkBaseURL)
                ?? defaults?.string(forKey: VisionBackendDefaultsKey.cloudBaseURL)
                ?? "https://ark.cn-beijing.volces.com/api/v3",
            textModelID: defaults?.string(forKey: CloudSettingsDefaultsKey.arkTextModelID)
                ?? defaults?.string(forKey: VisionBackendDefaultsKey.cloudTextModel)
                ?? "",
            frameModelID: defaults?.string(forKey: CloudSettingsDefaultsKey.arkFrameModelID)
                ?? defaults?.string(forKey: VisionBackendDefaultsKey.cloudModel)
                ?? "",
            hasAPIKey: credential(.arkAPIKey)?.isEmpty == false
        )
        let region = LASServiceRegion(
            rawValue: defaults?.string(forKey: CloudSettingsDefaultsKey.lasRegion) ?? "cn-beijing"
        ) ?? .cnBeijing
        let las = LASBackendSettings(
            isEnabled: defaults?.bool(forKey: CloudSettingsDefaultsKey.lasEnabled) ?? false,
            region: region,
            videoStoryboardOperatorID: defaults?.string(forKey: CloudSettingsDefaultsKey.lasVideoStoryboardOperatorID) ?? "",
            videoFineUnderstandingOperatorID: defaults?.string(forKey: CloudSettingsDefaultsKey.lasVideoFineUnderstandingOperatorID) ?? "",
            scriptGenerationOperatorID: defaults?.string(forKey: CloudSettingsDefaultsKey.lasScriptGenerationOperatorID) ?? "",
            enhancedASROperatorID: defaults?.string(forKey: CloudSettingsDefaultsKey.lasEnhancedASROperatorID) ?? "",
            hasAPIKey: credential(.lasAPIKey)?.isEmpty == false
        )
        let hasSTS = CloudCredentialSlot.allCases
            .filter { $0 == .tosAccessKeyID || $0 == .tosSecretAccessKey || $0 == .tosSecurityToken }
            .allSatisfy { credential($0)?.isEmpty == false }
        let staging = TOSStagingSettings(
            bucket: defaults?.string(forKey: CloudSettingsDefaultsKey.tosBucket) ?? "",
            objectPrefix: defaults?.string(forKey: CloudSettingsDefaultsKey.tosObjectPrefix) ?? "engram/",
            credentialReferenceID: defaults?.string(forKey: CloudSettingsDefaultsKey.tosCredentialReferenceID) ?? "",
            temporaryCredentialExpiresAt: defaults?.object(forKey: CloudSettingsDefaultsKey.tosCredentialExpiresAt) as? Date,
            hasTemporaryCredentials: hasSTS,
            maximumUploadMegabytes: max(
                1,
                defaults?.integer(forKey: CloudSettingsDefaultsKey.tosMaximumUploadMegabytes)
                    ?? defaults?.integer(forKey: VisionBackendDefaultsKey.cloudVideoUploadMaximumMB)
                    ?? 2_000
            )
        )
        return VisionBackendSettings(requestedMode: requestedMode, ark: ark, las: las, staging: staging)
    }

    func save(_ settings: VisionBackendSettings) {
        defaults?.set(settings.requestedMode.rawValue, forKey: CloudSettingsDefaultsKey.requestedMode)
        defaults?.set(settings.ark.baseURL, forKey: CloudSettingsDefaultsKey.arkBaseURL)
        defaults?.set(settings.ark.textModelID, forKey: CloudSettingsDefaultsKey.arkTextModelID)
        defaults?.set(settings.ark.frameModelID, forKey: CloudSettingsDefaultsKey.arkFrameModelID)
        defaults?.set(settings.las.isEnabled, forKey: CloudSettingsDefaultsKey.lasEnabled)
        defaults?.set(settings.las.region.rawValue, forKey: CloudSettingsDefaultsKey.lasRegion)
        defaults?.set(settings.las.videoStoryboardOperatorID, forKey: CloudSettingsDefaultsKey.lasVideoStoryboardOperatorID)
        defaults?.set(settings.las.videoFineUnderstandingOperatorID, forKey: CloudSettingsDefaultsKey.lasVideoFineUnderstandingOperatorID)
        defaults?.set(settings.las.scriptGenerationOperatorID, forKey: CloudSettingsDefaultsKey.lasScriptGenerationOperatorID)
        defaults?.set(settings.las.enhancedASROperatorID, forKey: CloudSettingsDefaultsKey.lasEnhancedASROperatorID)
        defaults?.set(settings.staging.bucket, forKey: CloudSettingsDefaultsKey.tosBucket)
        defaults?.set(settings.staging.objectPrefix, forKey: CloudSettingsDefaultsKey.tosObjectPrefix)
        defaults?.set(settings.staging.credentialReferenceID, forKey: CloudSettingsDefaultsKey.tosCredentialReferenceID)
        defaults?.set(settings.staging.temporaryCredentialExpiresAt, forKey: CloudSettingsDefaultsKey.tosCredentialExpiresAt)
        defaults?.set(settings.staging.maximumUploadMegabytes, forKey: CloudSettingsDefaultsKey.tosMaximumUploadMegabytes)

        // Mirror the Ark fields for existing text/frame consumers during the additive migration.
        defaults?.set(settings.kind.rawValue, forKey: VisionBackendDefaultsKey.kind)
        defaults?.set(settings.ark.baseURL, forKey: VisionBackendDefaultsKey.cloudBaseURL)
        defaults?.set(settings.ark.textModelID, forKey: VisionBackendDefaultsKey.cloudTextModel)
        defaults?.set(settings.ark.frameModelID, forKey: VisionBackendDefaultsKey.cloudModel)
        defaults?.set(settings.cloudVideoMode.rawValue, forKey: VisionBackendDefaultsKey.cloudVideoMode)
        defaults?.set(false, forKey: VisionBackendDefaultsKey.cloudVideoUploadConsent)
        defaults?.set(settings.staging.maximumUploadMegabytes, forKey: VisionBackendDefaultsKey.cloudVideoUploadMaximumMB)
    }

    @discardableResult
    func setCredential(_ slot: CloudCredentialSlot, value: String?) -> Bool {
        guard KeychainStore.set(value, for: Self.account(for: slot)) else { return false }
        let key = CloudSettingsDefaultsKey.credentialRevision(slot)
        defaults?.set((defaults?.integer(forKey: key) ?? 0) + 1, forKey: key)
        return true
    }

    func credential(_ slot: CloudCredentialSlot) -> String? {
        KeychainStore.string(for: Self.account(for: slot))
    }

    func configurationFingerprints() -> [CloudProviderRole: String] {
        let settings = load()
        let arkRevision = revision(.arkAPIKey)
        let lasRevision = revision(.lasAPIKey)
        let stagingRevision = [
            revision(.tosAccessKeyID),
            revision(.tosSecretAccessKey),
            revision(.tosSecurityToken),
        ].joined(separator: ".")
        let arkBase = [settings.ark.baseURL, settings.ark.textModelID, settings.ark.frameModelID, arkRevision]
        let lasBase = [settings.las.region.rawValue, lasRevision, Self.contractRevision]
        let staging = [
            settings.las.region.rawValue,
            settings.staging.bucket,
            settings.staging.objectPrefix,
            settings.staging.credentialReferenceID,
            stagingRevision,
            Self.contractRevision,
        ]
        return [
            .arkText: Self.fingerprint(arkBase + ["text"]),
            .arkFrame: Self.fingerprint(arkBase + ["frame"]),
            .lasVideoStoryboard: Self.fingerprint(lasBase + [settings.las.videoStoryboardOperatorID]),
            .lasVideoFineUnderstanding: Self.fingerprint(lasBase + [settings.las.videoFineUnderstandingOperatorID]),
            .lasScriptGeneration: Self.fingerprint(lasBase + [settings.las.scriptGenerationOperatorID]),
            .lasEnhancedASR: Self.fingerprint(lasBase + [settings.las.enhancedASROperatorID]),
            .mediaStaging: Self.fingerprint(staging),
        ]
    }

    var routingSignature: String {
        let settings = load()
        return ([settings.requestedMode.rawValue] + configurationFingerprints().keys.sorted().map {
            "\($0.rawValue)=\(configurationFingerprints()[$0] ?? "")"
        }).joined(separator: "|")
    }

    private func revision(_ slot: CloudCredentialSlot) -> String {
        String(defaults?.integer(forKey: CloudSettingsDefaultsKey.credentialRevision(slot)) ?? 0)
    }

    private static func account(for slot: CloudCredentialSlot) -> String {
        switch slot {
        case .arkAPIKey: VisionBackendKeychainAccount.arkAPIKey
        case .lasAPIKey: VisionBackendKeychainAccount.lasAPIKey
        case .tosAccessKeyID: VisionBackendKeychainAccount.tosAccessKeyID
        case .tosSecretAccessKey: VisionBackendKeychainAccount.tosSecretAccessKey
        case .tosSecurityToken: VisionBackendKeychainAccount.tosSecurityToken
        }
    }

    private static func fingerprint(_ components: [String]) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in components.joined(separator: "|").utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return String(value, radix: 16)
    }
}
