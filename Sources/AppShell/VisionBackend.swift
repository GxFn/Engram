import CloudVision
import EngineKit
import Foundation
import ScriptCore

enum VisionBackendDefaultsKey {
    static let kind = "visionBackend" // "onDevice" | "cloud" — app-wide AI mode
    static let cloudBaseURL = "cloudVLMBaseURL"
    static let cloudModel = "cloudVLMModel" // vision model id
    static let cloudTextModel = "cloudTextModel" // text/LLM model id
}

enum VisionBackendKeychainAccount {
    static let cloudAPIKey = "cloudVLMAPIKey" // shared by text + vision
}

/// The app-wide AI mode is a single switch (本地 ↔ 云端). In 云端 mode, both the text LLM and
/// the vision backend run on the same cloud endpoint/key; in 本地 mode both run on-device.
enum CloudAIResolver {
    static func isCloudMode(defaults: UserDefaults?) -> Bool {
        // Default to cloud when the user hasn't chosen a mode yet (low-memory devices can't run
        // the local models well). Unconfigured cloud gracefully falls back to on-device below.
        (defaults?.string(forKey: VisionBackendDefaultsKey.kind) ?? "cloud") == "cloud"
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

    /// Cloud vision generator (frame → text) when configured; nil means use on-device.
    static func makeVisionGenerator(defaults: UserDefaults?) -> (any VisionScriptGenerating)? {
        guard let (baseURL, apiKey) = credentials(defaults: defaults),
              let model = defaults?.string(forKey: VisionBackendDefaultsKey.cloudModel),
              !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return OpenAICompatibleVLMGenerator(
            configuration: .init(baseURL: baseURL, model: model, apiKey: apiKey)
        )
    }

    /// Cloud text engine (scripting + Q&A) when configured; nil means use the on-device engine.
    static func makeLLMEngine(defaults: UserDefaults?) -> (any LLMEngine)? {
        guard let (baseURL, apiKey) = credentials(defaults: defaults),
              let model = defaults?.string(forKey: VisionBackendDefaultsKey.cloudTextModel),
              !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return OpenAICompatibleLLMEngine(
            configuration: .init(baseURL: baseURL, model: model, apiKey: apiKey)
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
