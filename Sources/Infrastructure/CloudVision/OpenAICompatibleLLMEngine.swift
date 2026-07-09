import EngineKit
import EngramLogging
import Foundation

/// Cloud text LLM over the OpenAI-compatible chat/completions API, so 云端 mode powers scripting
/// and Q&A (not just vision). Shares credentials with the cloud VLM (same Volcengine/DeepSeek key).
/// v1 is non-streaming: the whole answer arrives at once, then a `.finished` event.
public struct CloudLLMConfiguration: Sendable, Hashable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String
    public var timeout: TimeInterval

    public init(baseURL: URL, model: String, apiKey: String, timeout: TimeInterval = 120) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
    }
}

public actor OpenAICompatibleLLMEngine: LLMEngine {
    public nonisolated let descriptor = EngineDescriptor(
        id: "cloud",
        displayName: "云端 AI",
        kind: .cloud
    )

    private let configuration: CloudLLMConfiguration
    private let dataForRequest: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(configuration: CloudLLMConfiguration) {
        self.init(configuration: configuration) { request in
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = request.timeoutInterval
            let session = URLSession(configuration: sessionConfiguration)
            return try await session.data(for: request)
        }
    }

    public init(
        configuration: CloudLLMConfiguration,
        dataForRequest: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.configuration = configuration
        self.dataForRequest = dataForRequest
    }

    public func load(_ model: ModelIdentity) async throws {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CloudVLMError.missingAPIKey
        }
    }

    public func unload() async {}

    public func generate(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = Date()
                do {
                    let content = try await complete(messages: request.messages, config: request.config)
                    if Task.isCancelled {
                        continuation.yield(.finished(.cancelled, Self.metrics(startedAt: startedAt, output: 0)))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.token(content))
                    continuation.yield(.finished(.stop, Self.metrics(startedAt: startedAt, output: Self.estimateTokens(content))))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.finished(.cancelled, Self.metrics(startedAt: startedAt, output: 0)))
                    continuation.finish()
                } catch {
                    Log.engine.error("Cloud LLM generation failed: \(String(describing: error), privacy: .public)")
                    continuation.yield(.finished(.error, Self.metrics(startedAt: startedAt, output: 0)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }

    public func countTokens(in text: String) async throws -> Int {
        Self.estimateTokens(text)
    }

    private func complete(messages: [ChatMessage], config: GenerationConfig) async throws -> String {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CloudVLMError.missingAPIKey
        }

        var request = URLRequest(url: Self.endpoint(base: configuration.baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.requestBody(model: configuration.model, messages: messages, config: config)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await dataForRequest(request)
        } catch let error as URLError where error.code == .cancelled {
            // Map transport cancellation (-999) to CancellationError so the stream reports
            // .finished(.cancelled) instead of surfacing a bogus generation failure.
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudVLMError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(String(decoding: data, as: UTF8.self).prefix(500))
            throw CloudVLMError.statusCode(http.statusCode, snippet)
        }

        let content = try Self.decodeContent(data)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudVLMError.emptyContent
        }
        return content
    }

    static func endpoint(base: URL) -> URL {
        base.path.hasSuffix("chat/completions") ? base : base.appendingPathComponent("chat/completions")
    }

    static func requestBody(model: String, messages: [ChatMessage], config: GenerationConfig) throws -> Data {
        let payload = TextChatRequest(
            model: model,
            messages: messages.map { TextChatRequest.Message(role: $0.role.rawValue, content: $0.content) },
            temperature: config.temperature,
            maxTokens: config.maxTokens
        )
        return try JSONEncoder().encode(payload)
    }

    static func decodeContent(_ data: Data) throws -> String {
        do {
            let response = try JSONDecoder().decode(TextChatResponse.self, from: data)
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

    /// Coarse token estimate (no cloud tokenizer available): CJK ≈ 1/char, else ≈ 0.3/char.
    static func estimateTokens(_ text: String) -> Int {
        var total = 0.0
        for scalar in text.unicodeScalars {
            total += scalar.value > 0x2E80 ? 1.0 : 0.3
        }
        return max(1, Int(total.rounded(.up)))
    }

    private nonisolated static func metrics(startedAt: Date, output: Int) -> GenerationMetrics {
        GenerationMetrics(
            firstTokenLatencyMillis: Date().timeIntervalSince(startedAt) * 1_000,
            tokensPerSecond: nil,
            outputTokenCount: output
        )
    }
}

private struct TextChatRequest: Encodable {
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
        let content: String
    }
}

private struct TextChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}
