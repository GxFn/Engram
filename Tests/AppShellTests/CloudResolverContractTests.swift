@testable import AppShell
import Foundation
import Testing

@Suite(.serialized)
struct CloudResolverContractTests {
    @Test
    func genericOpenAIEndpointDoesNotInventDeepVideoRoutesOrCapabilities() throws {
        let suiteName = "EngramCloudResolverContractTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let existingKey = KeychainStore.string(for: VisionBackendKeychainAccount.cloudAPIKey)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            KeychainStore.set(existingKey, for: VisionBackendKeychainAccount.cloudAPIKey)
        }
        defaults.set("cloud", forKey: VisionBackendDefaultsKey.kind)
        defaults.set(
            "https://ark.cn-beijing.volces.com/api/v3",
            forKey: VisionBackendDefaultsKey.cloudBaseURL
        )
        defaults.set("ep-frame-only", forKey: VisionBackendDefaultsKey.cloudModel)
        defaults.set("ep-text", forKey: VisionBackendDefaultsKey.cloudTextModel)
        defaults.set("deep", forKey: VisionBackendDefaultsKey.cloudVideoMode)
        defaults.set(true, forKey: VisionBackendDefaultsKey.cloudVideoUploadConsent)
        defaults.set(50, forKey: VisionBackendDefaultsKey.cloudVideoUploadMaximumMB)
        try #require(KeychainStore.set("contract-test-key", for: VisionBackendKeychainAccount.cloudAPIKey))

        let configuration = CloudAIResolver.makeVideoConfiguration(defaults: defaults)

        // A generic OpenAI-compatible endpoint proves only text/image chat. Deep-video routing
        // requires an explicit provider profile and a real tiny-media capability probe.
        #expect(configuration == nil)
    }
}
