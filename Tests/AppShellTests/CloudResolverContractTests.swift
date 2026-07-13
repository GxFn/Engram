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

        let resolved = CloudAIResolver.makeVideoConfiguration(defaults: defaults)

        // A generic OpenAI-compatible endpoint proves only text/image chat. The requested mode
        // remains deep for an auditable resolver decision, but the profile must declare no
        // full-video job transport and therefore can only degrade to cloudStandard.
        let configuration = try #require(resolved)
        #expect(configuration.requestedMode == .cloudDeep)
        #expect(configuration.profile.transport == .frameChat)
        #expect(configuration.profile.capabilityURL.path.hasSuffix("/chat/completions"))
        #expect(configuration.profile.jobURL == configuration.profile.capabilityURL)
        #expect(!configuration.profile.jobURL.path.contains("/video/jobs"))
        #expect(configuration.profile.declaredCapabilities == [.frameUnderstanding])
    }
}
