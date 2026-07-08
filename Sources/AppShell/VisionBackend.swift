import CloudVision
import Foundation
import ScriptCore

enum VisionBackendDefaultsKey {
    static let kind = "visionBackend" // "onDevice" | "cloud"
    static let cloudBaseURL = "cloudVLMBaseURL"
    static let cloudModel = "cloudVLMModel"
}

enum VisionBackendKeychainAccount {
    static let cloudAPIKey = "cloudVLMAPIKey"
}

/// Resolves the user's vision-backend choice into a generator. Returns a cloud generator only
/// when cloud is selected AND fully configured (base URL + model + Keychain key); otherwise nil,
/// which means the on-device MLX Qwen3-VL backend is used. This is the single switch point
/// between on-device and cloud — everything downstream is backend-neutral.
enum VisionBackendResolver {
    static func makeGenerator(defaults: UserDefaults?) -> (any VisionScriptGenerating)? {
        guard let defaults,
              defaults.string(forKey: VisionBackendDefaultsKey.kind) == "cloud" else {
            return nil
        }
        guard let baseURLString = defaults.string(forKey: VisionBackendDefaultsKey.cloudBaseURL),
              !baseURLString.trimmingCharacters(in: .whitespaces).isEmpty,
              let baseURL = URL(string: baseURLString),
              let model = defaults.string(forKey: VisionBackendDefaultsKey.cloudModel),
              !model.trimmingCharacters(in: .whitespaces).isEmpty,
              let key = KeychainStore.string(for: VisionBackendKeychainAccount.cloudAPIKey),
              !key.isEmpty else {
            return nil
        }
        return OpenAICompatibleVLMGenerator(
            configuration: .init(baseURL: baseURL, model: model, apiKey: key)
        )
    }
}
