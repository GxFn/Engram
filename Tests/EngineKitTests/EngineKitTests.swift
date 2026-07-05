import Testing
@testable import EngineKit

@Test func generationConfigDefaults() {
    let config = GenerationConfig.default
    #expect(config.temperature == 0.7)
    #expect(config.topP == 0.9)
    #expect(config.maxTokens == 1024)
}

@Test func chatMessageRolesAreComplete() {
    #expect(ChatMessage.Role.allCases == [.system, .user, .assistant])
}
