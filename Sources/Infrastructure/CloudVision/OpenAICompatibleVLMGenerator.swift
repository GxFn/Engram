import EngineKit
import EngramLogging
import Foundation
import ScriptCore
import VideoUnderstanding

/// Cloud vision backend for keyframe → text generation, using the OpenAI-compatible
/// chat/completions shape with multimodal `image_url` content. One implementation covers
/// Volcengine Doubao, DeepSeek, Aliyun Qwen-VL, Zhipu GLM-4V, OpenAI, etc. — differing only
/// by `baseURL` + `model`. Conforms to the same `VisionScriptGenerating` seam as the on-device
/// MLX runtime, so the script composer, prompt, and JSON decoding are shared across backends.
public struct CloudVLMConfiguration: Sendable, Hashable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String
    public var timeout: TimeInterval

    public init(baseURL: URL, model: String, apiKey: String, timeout: TimeInterval = 60) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
    }
}

public enum CloudVLMError: Error, Equatable, Sendable {
    case missingAPIKey
    case invalidResponse
    case statusCode(Int, String)
    case emptyContent
    case decodingFailed(String)
}

extension CloudVLMError: LocalizedError {
    // Surfaced verbatim in the UI so a misconfigured model/endpoint/key is diagnosable on device
    // (the server body carried by `.statusCode` is the actual reason, e.g. an unknown model id).
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "云端未配置 API Key。"
        case .invalidResponse:
            return "云端返回了无法识别的响应。"
        case let .statusCode(code, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "云端服务错误 (HTTP \(code))。" : "云端服务错误 (HTTP \(code)): \(detail)"
        case .emptyContent:
            return "云端返回了空内容。"
        case let .decodingFailed(detail):
            return "云端响应解析失败: \(detail)"
        }
    }
}

public struct OpenAICompatibleVLMGenerator: VisionScriptGenerating {
    private let configuration: CloudVLMConfiguration
    private let dataForRequest: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(configuration: CloudVLMConfiguration) {
        self.init(configuration: configuration) { request in
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = request.timeoutInterval
            let session = URLSession(configuration: sessionConfiguration)
            return try await session.data(for: request)
        }
    }

    public init(
        configuration: CloudVLMConfiguration,
        dataForRequest: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.configuration = configuration
        self.dataForRequest = dataForRequest
    }

    public func generate(
        prompt: String,
        frames: [SampledFrame],
        config: GenerationConfig
    ) async throws -> String {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CloudVLMError.missingAPIKey
        }

        var request = URLRequest(url: Self.endpoint(base: configuration.baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.requestBody(
            model: configuration.model,
            prompt: prompt,
            frames: frames,
            config: config
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await dataForRequest(request)
        } catch let error as URLError where error.code == .cancelled {
            // A cancelled transport call (-999) is a cancellation, not a vision failure — without
            // this the composer's generic catch would save a misleading transcript-dump "success".
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudVLMError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(String(decoding: data, as: UTF8.self).prefix(500))
            Log.scriptComposer.error("Cloud VLM HTTP \(http.statusCode, privacy: .public)")
            throw CloudVLMError.statusCode(http.statusCode, snippet)
        }

        let content = try Self.decodeContent(data)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudVLMError.emptyContent
        }
        return content
    }

    static func endpoint(base: URL) -> URL {
        // Accept a base like ".../api/v3" or ".../v1"; append the standard path unless the
        // caller already pointed at chat/completions.
        if base.path.hasSuffix("chat/completions") {
            return base
        }
        return base.appendingPathComponent("chat/completions")
    }

    static func requestBody(
        model: String,
        prompt: String,
        frames: [SampledFrame],
        config: GenerationConfig
    ) throws -> Data {
        var content: [ChatContent] = [.text(prompt)]
        for frame in frames {
            let base64 = frame.jpegData.base64EncodedString()
            content.append(.imageURL("data:image/jpeg;base64,\(base64)"))
        }
        let payload = ChatRequest(
            model: model,
            messages: [ChatRequest.Message(role: "user", content: content)],
            temperature: config.temperature,
            maxTokens: config.maxTokens
        )
        return try JSONEncoder().encode(payload)
    }

    static func decodeContent(_ data: Data) throws -> String {
        do {
            let response = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let content = response.choices.first?.message.content else {
                throw CloudVLMError.emptyContent
            }
            return content
        } catch let error as CloudVLMError {
            throw error
        } catch {
            throw CloudVLMError.decodingFailed(String(describing: error))
        }
    }
}

// MARK: - Wire types (OpenAI-compatible chat/completions)

private struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: [ChatContent]
    }
}

private enum ChatContent: Encodable {
    case text(String)
    case imageURL(String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    struct ImageURL: Encodable {
        let url: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .imageURL(url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: url), forKey: .imageURL)
        }
    }
}

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}
