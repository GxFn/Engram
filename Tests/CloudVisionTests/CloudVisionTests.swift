import EngineKit
import Foundation
import ScriptCore
import Testing
import VideoUnderstanding
@testable import CloudVision

@Test func requestBodyEncodesPromptTextThenImageParts() throws {
    let frame = SampledFrame(timestampSeconds: 1, jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]))
    let data = try OpenAICompatibleVLMGenerator.requestBody(
        model: "doubao-vision",
        prompt: "分析这条视频",
        frames: [frame],
        config: GenerationConfig(temperature: 0.2, topP: 0.9, maxTokens: 1_500)
    )

    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["model"] as? String == "doubao-vision")
    #expect(json["max_tokens"] as? Int == 1_500)

    let messages = try #require(json["messages"] as? [[String: Any]])
    let content = try #require(messages.first?["content"] as? [[String: Any]])
    #expect(content.count == 2)
    #expect(content[0]["type"] as? String == "text")
    #expect(content[0]["text"] as? String == "分析这条视频")
    #expect(content[1]["type"] as? String == "image_url")
    let imageURL = try #require(content[1]["image_url"] as? [String: Any])
    #expect((imageURL["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
}

@Test func generateSendsAuthAndReturnsParsedContent() async throws {
    let responseJSON = #"{"choices":[{"message":{"content":"{\"title\":\"x\"}"}}]}"#
    let generator = OpenAICompatibleVLMGenerator(
        configuration: .init(baseURL: URL(string: "https://example.com/api/v3")!, model: "m", apiKey: "secret-key")
    ) { request in
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        #expect(request.url?.absoluteString == "https://example.com/api/v3/chat/completions")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(responseJSON.utf8), response)
    }

    let output = try await generator.generate(prompt: "p", frames: [], config: .default)
    #expect(output.contains("\"title\""))
}

@Test func generateThrowsMissingAPIKeyForBlankKey() async {
    let generator = OpenAICompatibleVLMGenerator(
        configuration: .init(baseURL: URL(string: "https://example.com")!, model: "m", apiKey: "   ")
    )
    await #expect(throws: CloudVLMError.missingAPIKey) {
        _ = try await generator.generate(prompt: "p", frames: [], config: .default)
    }
}

@Test func generateThrowsOnNon2xxStatus() async {
    let generator = OpenAICompatibleVLMGenerator(
        configuration: .init(baseURL: URL(string: "https://example.com")!, model: "m", apiKey: "k")
    ) { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        return (Data("unauthorized".utf8), response)
    }
    await #expect(throws: CloudVLMError.self) {
        _ = try await generator.generate(prompt: "p", frames: [], config: .default)
    }
}

@Test func endpointPreservesExplicitChatCompletionsPath() {
    let explicit = URL(string: "https://example.com/v1/chat/completions")!
    #expect(OpenAICompatibleVLMGenerator.endpoint(base: explicit) == explicit)
    let base = URL(string: "https://example.com/api/v3")!
    #expect(OpenAICompatibleVLMGenerator.endpoint(base: base).absoluteString == "https://example.com/api/v3/chat/completions")
}
