import EngineKit
import EngramLogging
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import OSLog
import Tokenizers

#if canImport(UIKit)
import UIKit
#endif

/// MLX-backed inference engine for local model files managed by ModelStore.
public actor MLXEngine: LLMEngine {
    public nonisolated let descriptor = EngineDescriptor(
        id: "mlx",
        displayName: "MLX",
        kind: .mlx
    )

    private nonisolated static let signposter = OSSignposter(
        subsystem: "com.gxfn.engram",
        category: "engine"
    )

    private let runtime: any MLXEngineRuntime
    private var session: (any MLXEngineSession)?
    private var memoryWarningTask: Task<Void, Never>?

    public init(modelDirectoryRoot: URL? = nil) {
        self.runtime = RealMLXEngineRuntime(
            modelDirectoryRoot: modelDirectoryRoot ?? Self.defaultModelDirectoryRoot()
        )
    }

    init(runtime: any MLXEngineRuntime) {
        self.runtime = runtime
    }

    deinit {
        memoryWarningTask?.cancel()
    }

    public func load(_ model: ModelIdentity) async throws {
        #if os(iOS) && targetEnvironment(simulator)
        throw EngineError.notImplemented("simulator unsupported - use a device or macOS")
        #else
        let signpostState = Self.signposter.beginInterval("MLXEngine.load")
        let startedAt = Date()

        do {
            session = try await runtime.load(model)
            startMemoryWarningObserverIfNeeded()

            let elapsedMillis = Date().timeIntervalSince(startedAt) * 1_000
            Log.engine.info(
                "Loaded MLX model \(model.id, privacy: .public) in \(elapsedMillis, format: .fixed(precision: 1)) ms"
            )
            Self.signposter.endInterval("MLXEngine.load", signpostState)
        } catch {
            Self.signposter.endInterval("MLXEngine.load", signpostState)
            Log.engine.error(
                "Failed to load MLX model \(model.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
        #endif
    }

    public func unload() async {
        session = nil
        await runtime.clearCache()
        Log.engine.info("Unloaded MLX model and cleared MLX cache")
    }

    public func generate(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        guard let session else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: EngineError.modelNotLoaded)
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = Date()
                var firstTokenLatencyMillis: Double?
                var fallbackOutputTokenCount = 0

                do {
                    let runtimeStream = try await session.generate(request)

                    for try await event in runtimeStream {
                        if Task.isCancelled {
                            throw CancellationError()
                        }

                        switch event {
                        case .text(let text):
                            guard !text.isEmpty else { continue }

                            if firstTokenLatencyMillis == nil {
                                firstTokenLatencyMillis = Date().timeIntervalSince(startedAt) * 1_000
                            }

                            fallbackOutputTokenCount += 1
                            continuation.yield(.token(text))

                        case .finished(let finish):
                            let metrics = GenerationMetrics(
                                firstTokenLatencyMillis: firstTokenLatencyMillis,
                                tokensPerSecond: finish.tokensPerSecond,
                                outputTokenCount: finish.outputTokenCount
                            )
                            continuation.yield(.finished(finish.reason, metrics))
                            continuation.finish()
                            return
                        }
                    }

                    let metrics = Self.metrics(
                        startedAt: startedAt,
                        firstTokenLatencyMillis: firstTokenLatencyMillis,
                        outputTokenCount: fallbackOutputTokenCount,
                        tokensPerSecond: nil
                    )
                    continuation.yield(.finished(.stop, metrics))
                    continuation.finish()
                } catch is CancellationError {
                    let metrics = Self.metrics(
                        startedAt: startedAt,
                        firstTokenLatencyMillis: firstTokenLatencyMillis,
                        outputTokenCount: fallbackOutputTokenCount,
                        tokensPerSecond: nil
                    )
                    Log.engine.warning("MLX generation cancelled")
                    continuation.yield(.finished(.cancelled, metrics))
                    continuation.finish()
                } catch {
                    let metrics = Self.metrics(
                        startedAt: startedAt,
                        firstTokenLatencyMillis: firstTokenLatencyMillis,
                        outputTokenCount: fallbackOutputTokenCount,
                        tokensPerSecond: nil
                    )
                    Log.engine.error(
                        "MLX generation failed: \(String(describing: error), privacy: .public)"
                    )
                    continuation.yield(.finished(.error, metrics))
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
        guard let session else {
            throw EngineError.modelNotLoaded
        }

        return try await session.countTokens(in: text)
    }

    private func startMemoryWarningObserverIfNeeded() {
        #if canImport(UIKit)
        guard memoryWarningTask == nil else { return }

        memoryWarningTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            )

            for await _ in notifications {
                guard !Task.isCancelled else { return }
                Log.engine.warning("Received memory warning; unloading MLX model")
                await self?.unload()
            }
        }
        #endif
    }

    private nonisolated static func metrics(
        startedAt: Date,
        firstTokenLatencyMillis: Double?,
        outputTokenCount: Int,
        tokensPerSecond: Double?
    ) -> GenerationMetrics {
        let sanitizedTokensPerSecond: Double?
        if let tokensPerSecond, tokensPerSecond.isFinite, tokensPerSecond >= 0 {
            sanitizedTokensPerSecond = tokensPerSecond
        } else {
            let elapsed = Date().timeIntervalSince(startedAt)
            sanitizedTokensPerSecond = elapsed > 0 && outputTokenCount > 0
                ? Double(outputTokenCount) / elapsed
                : nil
        }

        return GenerationMetrics(
            firstTokenLatencyMillis: firstTokenLatencyMillis,
            tokensPerSecond: sanitizedTokensPerSecond,
            outputTokenCount: outputTokenCount
        )
    }

    private nonisolated static func defaultModelDirectoryRoot() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        // Keep this default in lockstep with ModelStore until W1.4 centralizes assembly.
        return applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }
}

protocol MLXEngineRuntime: Sendable {
    func load(_ model: ModelIdentity) async throws -> any MLXEngineSession
    func clearCache() async
}

protocol MLXEngineSession: Sendable {
    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<MLXEngineRuntimeEvent, Error>
    func countTokens(in text: String) async throws -> Int
}

enum MLXEngineRuntimeEvent: Sendable {
    case text(String)
    case finished(MLXEngineRuntimeFinish)
}

struct MLXEngineRuntimeFinish: Sendable {
    let reason: FinishReason
    let outputTokenCount: Int
    let tokensPerSecond: Double?

    init(reason: FinishReason, outputTokenCount: Int, tokensPerSecond: Double?) {
        self.reason = reason
        self.outputTokenCount = outputTokenCount
        self.tokensPerSecond = tokensPerSecond
    }
}

struct RealMLXEngineRuntime: MLXEngineRuntime {
    private static let manifestFileName = ".engram-model.json"

    private let modelDirectoryRoot: URL
    private let tokenizerLoader: any TokenizerLoader

    init(
        modelDirectoryRoot: URL,
        tokenizerLoader: any TokenizerLoader = TransformersTokenizerLoader()
    ) {
        self.modelDirectoryRoot = modelDirectoryRoot
        self.tokenizerLoader = tokenizerLoader
    }

    func load(_ model: ModelIdentity) async throws -> any MLXEngineSession {
        let directory = try resolvedModelDirectory(for: model)
        guard try containsPayloadFile(in: directory) else {
            throw EngineError.notImplemented(
                "model artifacts missing at \(directory.path); download remains ModelStore/onboarding scope"
            )
        }

        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: tokenizerLoader
        )
        return RealMLXEngineSession(container: container)
    }

    func clearCache() async {
        Memory.clearCache()
    }

    func resolvedModelDirectory(for model: ModelIdentity) throws -> URL {
        let canonicalDirectory = canonicalModelDirectory(for: model)
        if try containsPayloadFile(in: canonicalDirectory) {
            return canonicalDirectory
        }

        return try manifestBackedDirectory(for: model) ?? canonicalDirectory
    }

    private func canonicalModelDirectory(for model: ModelIdentity) -> URL {
        model.id.split(separator: "/").reduce(modelDirectoryRoot) { url, component in
            url.appendingPathComponent(String(component), isDirectory: true)
        }
    }

    private func manifestBackedDirectory(for model: ModelIdentity) throws -> URL? {
        guard FileManager.default.fileExists(atPath: modelDirectoryRoot.path) else {
            return nil
        }

        var match: URL?
        try visitDirectories(under: modelDirectoryRoot) { directory in
            guard match == nil else { return }

            let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                return
            }

            let data = try Data(contentsOf: manifestURL)
            let manifestModel = try JSONDecoder().decode(ModelIdentity.self, from: data)
            if manifestModel == model, try containsPayloadFile(in: directory) {
                match = directory
            }
        }

        return match
    }

    private func containsPayloadFile(in directory: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return false
        }

        var foundPayload = false
        try visitRegularFiles(under: directory) { fileURL in
            if fileURL.lastPathComponent != Self.manifestFileName {
                foundPayload = true
            }
        }

        return foundPayload
    }

    private func visitDirectories(under root: URL, _ body: (URL) throws -> Void) throws {
        try body(root)

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try body(url)
            }
        }
    }

    private func visitRegularFiles(under root: URL, _ body: (URL) throws -> Void) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                try body(url)
            }
        }
    }
}

struct RealMLXEngineSession: MLXEngineSession {
    let container: ModelContainer

    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<MLXEngineRuntimeEvent, Error> {
        let userInput = UserInput(chat: Self.chatMessages(from: request.messages))
        let input = try await container.prepare(input: userInput)
        let parameters = GenerateParameters(
            maxTokens: request.config.maxTokens,
            temperature: Float(request.config.temperature),
            topP: Float(request.config.topP)
        )
        let stream = try await container.generate(input: input, parameters: parameters)

        return AsyncThrowingStream { continuation in
            let task = Task {
                for await generation in stream {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }

                    switch generation {
                    case .chunk(let text):
                        continuation.yield(.text(text))

                    case .info(let info):
                        continuation.yield(.finished(Self.finish(from: info)))
                        continuation.finish()
                        return

                    case .toolCall:
                        Log.engine.warning("MLX emitted a tool call; Engram W1.3 ignores tool calls")
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }

    func countTokens(in text: String) async throws -> Int {
        await container.encode(text).count
    }

    static func chatMessages(from messages: [ChatMessage]) -> [Chat.Message] {
        messages.map { message in
            switch message.role {
            case .system:
                .system(message.content)
            case .user:
                .user(message.content)
            case .assistant:
                .assistant(message.content)
            }
        }
    }

    private static func finish(from info: GenerateCompletionInfo) -> MLXEngineRuntimeFinish {
        let reason: FinishReason
        switch info.stopReason {
        case .stop:
            reason = .stop
        case .length:
            reason = .length
        case .cancelled:
            reason = .cancelled
        }

        let tokensPerSecond = info.tokensPerSecond.isFinite && info.tokensPerSecond >= 0
            ? info.tokensPerSecond
            : nil

        return MLXEngineRuntimeFinish(
            reason: reason,
            outputTokenCount: info.generationTokenCount,
            tokensPerSecond: tokensPerSecond
        )
    }
}

struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizersTokenizerBridge(upstream: tokenizer)
    }
}

struct TokenizersTokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let upstream: any Tokenizers.Tokenizer

    init(upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
