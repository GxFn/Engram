import CloudVision
import EngineKit
import Foundation
import ScriptCore
import StoryboardCore

enum VisionBackendDefaultsKey {
    static let kind = "visionBackend" // "onDevice" | "cloud" — app-wide AI mode
    static let cloudBaseURL = "cloudVLMBaseURL"
    static let cloudModel = "cloudVLMModel" // vision model id
    static let cloudTextModel = "cloudTextModel" // text/LLM model id
    static let cloudVideoMode = "cloudVideoAnalysisMode"
    static let cloudVideoUploadConsent = "cloudVideoUploadConsent"
    static let cloudVideoUploadMaximumMB = "cloudVideoUploadMaximumMB"
}

enum VisionBackendKeychainAccount {
    static let cloudAPIKey = "cloudVLMAPIKey" // shared by text + vision
}

/// The app-wide AI mode is a single switch (本地 ↔ 云端). In 云端 mode, both the text LLM and
/// the vision backend run on the same cloud endpoint/key; in 本地 mode both run on-device.
enum CloudAIResolver {
    struct VideoConfiguration: Sendable {
        let profile: CloudProviderProfile
        let requestedMode: EffectiveCloudMode
        let consent: MediaUploadConsent
        let bearerToken: String
        let consumeUploadConsent: @Sendable () async -> Bool
    }
    static func isCloudMode(defaults: UserDefaults?) -> Bool {
        // Default to cloud when the user hasn't chosen a mode yet (low-memory devices can't run
        // the local models well). Unconfigured cloud gracefully falls back to on-device below.
        (defaults?.string(forKey: VisionBackendDefaultsKey.kind) ?? "cloud") == "cloud"
    }

    /// Cheap signature of the whole AI configuration (mode + base URL + both model ids + whether a
    /// key exists). It changes whenever the user edits any of these, so the shell can rebuild the
    /// engine + video pipeline on a model-string change — not only on a 云端/本地 switch.
    static func configSignature(defaults: UserDefaults?) -> String {
        let kind = defaults?.string(forKey: VisionBackendDefaultsKey.kind) ?? "cloud"
        let base = defaults?.string(forKey: VisionBackendDefaultsKey.cloudBaseURL) ?? ""
        let vision = defaults?.string(forKey: VisionBackendDefaultsKey.cloudModel) ?? ""
        let text = defaults?.string(forKey: VisionBackendDefaultsKey.cloudTextModel) ?? ""
        let hasKey = KeychainStore.string(for: VisionBackendKeychainAccount.cloudAPIKey)?.isEmpty == false
        let videoMode = defaults?.string(forKey: VisionBackendDefaultsKey.cloudVideoMode) ?? "standard"
        let uploadConsent = defaults?.bool(forKey: VisionBackendDefaultsKey.cloudVideoUploadConsent) ?? false
        let uploadMB = defaults?.integer(forKey: VisionBackendDefaultsKey.cloudVideoUploadMaximumMB) ?? 200
        return [kind, base, vision, text, hasKey ? "k" : "-", videoMode, uploadConsent ? "upload" : "no-upload", String(uploadMB)].joined(separator: "|")
    }

    /// Cloud is usable only when mode is cloud AND base URL + Keychain key are present.
    private static func credentials(defaults: UserDefaults?) -> (baseURL: URL, apiKey: String)? {
        guard isCloudMode(defaults: defaults),
              let baseURLString = defaults?.string(forKey: VisionBackendDefaultsKey.cloudBaseURL),
              !baseURLString.trimmingCharacters(in: .whitespaces).isEmpty,
              let baseURL = URL(string: baseURLString),
              let apiKey = KeychainStore.string(for: VisionBackendKeychainAccount.cloudAPIKey),
              !apiKey.isEmpty else {
            return nil
        }
        return (baseURL, apiKey)
    }

    /// Cloud is ready only when EVERYTHING it needs is present: mode, base URL, key, and BOTH model
    /// ids. Gating text/vision independently let a partial config silently split the pipeline
    /// (e.g. text on cloud, vision on device) while the UI promises 云端 mode runs both on the
    /// cloud endpoint — all-or-nothing keeps the mode honest.
    static func cloudReady(defaults: UserDefaults?) -> Bool {
        guard credentials(defaults: defaults) != nil else { return false }
        let vision = defaults?.string(forKey: VisionBackendDefaultsKey.cloudModel) ?? ""
        let text = defaults?.string(forKey: VisionBackendDefaultsKey.cloudTextModel) ?? ""
        return !vision.trimmingCharacters(in: .whitespaces).isEmpty
            && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Cloud vision generator (frame → text) when fully configured; nil means use on-device.
    static func makeVisionGenerator(defaults: UserDefaults?) -> (any VisionScriptGenerating)? {
        guard cloudReady(defaults: defaults),
              let (baseURL, apiKey) = credentials(defaults: defaults),
              let model = defaults?.string(forKey: VisionBackendDefaultsKey.cloudModel) else {
            return nil
        }
        return OpenAICompatibleVLMGenerator(
            configuration: .init(baseURL: baseURL, model: model, apiKey: apiKey)
        )
    }

    /// Cloud text engine (scripting + Q&A) when fully configured; nil means use on-device.
    static func makeLLMEngine(defaults: UserDefaults?) -> (any LLMEngine)? {
        guard cloudReady(defaults: defaults),
              let (baseURL, apiKey) = credentials(defaults: defaults),
              let model = defaults?.string(forKey: VisionBackendDefaultsKey.cloudTextModel) else {
            return nil
        }
        return OpenAICompatibleLLMEngine(
            configuration: .init(baseURL: baseURL, model: model, apiKey: apiKey)
        )
    }

    static func makeVideoConfiguration(defaults: UserDefaults?) -> VideoConfiguration? {
        guard cloudReady(defaults: defaults),
              let (baseURL, apiKey) = credentials(defaults: defaults)
        else { return nil }
        let mode = defaults?.string(forKey: VisionBackendDefaultsKey.cloudVideoMode) ?? "standard"
        // A generic OpenAI-compatible or Ark /api/v3 endpoint proves frame/image chat only.
        // Keep the user's deep request in the decision record, but expose only this honest
        // frame-chat profile so the resolver visibly degrades to cloudStandard without ever
        // manufacturing provider video routes from the chat base URL.
        let maximumMB = max(1, defaults?.integer(forKey: VisionBackendDefaultsKey.cloudVideoUploadMaximumMB) ?? 200)
        let uploadEnabled = false
        let gate = OneShotUploadConsentGate(enabled: uploadEnabled)
        nonisolated(unsafe) let capturedDefaults = defaults
        let profile = CloudProviderProfile.frameChat(
            id: baseURL.host ?? "configured-cloud",
            displayName: baseURL.host ?? "Configured cloud video provider",
            baseURL: baseURL
        )
        return VideoConfiguration(
            profile: profile,
            requestedMode: mode == "deep" ? .cloudDeep : .cloudStandard,
            consent: MediaUploadConsent(
                allowsUpload: uploadEnabled,
                maximumBytes: Int64(maximumMB) * 1_024 * 1_024
            ),
            bearerToken: apiKey,
            consumeUploadConsent: {
                guard await gate.consume() else { return false }
                capturedDefaults?.set(false, forKey: VisionBackendDefaultsKey.cloudVideoUploadConsent)
                return true
            }
        )
    }

    /// Synthetic model identity for the cloud engine (large context so prompt trimming is rare).
    static let cloudModelIdentity = ModelIdentity(
        id: "cloud",
        family: "cloud",
        quantization: "cloud",
        contextLength: 32_768,
        estimatedMemoryBytes: 0
    )
}

private actor OneShotUploadConsentGate {
    private var enabled: Bool

    init(enabled: Bool) { self.enabled = enabled }

    func consume() -> Bool {
        guard enabled else { return false }
        enabled = false
        return true
    }
}
