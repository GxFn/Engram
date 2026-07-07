import CoreImage
import EngineKit
import EngramLogging
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import ModelStore
import Tokenizers
import VideoUnderstanding

/// Runtime seam used by Qwen3-VL script composition to generate text from
/// one prompt plus zero or more image attachments.
public protocol QwenVLGenerating: Sendable {
    func generate(
        prompt: String,
        frames: [SampledFrame],
        config: GenerationConfig
    ) async throws -> String
}

/// Runtime seam used by Qwen3VLDescriber for one-frame descriptions.
public protocol QwenVLFrameGenerating: Sendable {
    func generateDescription(
        for frame: SampledFrame,
        prompt: String,
        config: GenerationConfig
    ) async throws -> String
}

/// MLX-VLM-backed Qwen3-VL container for local model folders managed by ModelStore.
public actor QwenVLContainer: QwenVLGenerating, QwenVLFrameGenerating {
    private let defaultModel: ModelIdentity
    private let runtime: any QwenVLRuntimeLoading
    private var session: (any QwenVLSession)?
    private var loadedModel: ModelIdentity?

    public init(
        model: ModelIdentity = ModelCatalog.qwen3VL_4B_4bit,
        modelDirectoryRoot: URL? = nil
    ) {
        self.defaultModel = model
        self.runtime = RealQwenVLRuntime(
            modelDirectoryRoot: modelDirectoryRoot ?? Self.defaultModelDirectoryRoot()
        )
    }

    init(model: ModelIdentity, runtime: any QwenVLRuntimeLoading) {
        self.defaultModel = model
        self.runtime = runtime
    }

    public func load() async throws {
        try await load(defaultModel)
    }

    public func load(_ model: ModelIdentity) async throws {
        #if os(iOS) && targetEnvironment(simulator)
        throw VideoUnderstandingError.visionUnavailable(
            "Qwen3-VL MLX-VLM runtime is unsupported on iOS Simulator; use a device or macOS."
        )
        #else
        do {
            session = try await runtime.load(model)
            loadedModel = model
            Log.frameVision.info("Loaded Qwen3-VL model \(model.id, privacy: .public)")
        } catch let error as VideoUnderstandingError {
            throw error
        } catch {
            Log.frameVision.error(
                "Failed to load Qwen3-VL model \(model.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw VideoUnderstandingError.visionUnavailable(
                "Qwen3-VL load failed for \(model.id): \(String(describing: error))"
            )
        }
        #endif
    }

    public func unload() async {
        session = nil
        loadedModel = nil
        await runtime.clearCache()
        Log.frameVision.info("Unloaded Qwen3-VL model and cleared MLX cache")
    }

    public func generate(
        prompt: String,
        frames: [SampledFrame],
        config: GenerationConfig = .init(temperature: 0.2, topP: 0.9, maxTokens: 1_024)
    ) async throws -> String {
        if session == nil {
            try await load(defaultModel)
        }

        guard let session else {
            throw VideoUnderstandingError.visionUnavailable("Qwen3-VL model is not loaded.")
        }

        do {
            return try await session.generate(prompt: prompt, frames: frames, config: config)
        } catch let error as VideoUnderstandingError {
            throw error
        } catch {
            Log.frameVision.error(
                "Qwen3-VL generation failed: \(String(describing: error), privacy: .public)"
            )
            throw VideoUnderstandingError.visionUnavailable(
                "Qwen3-VL generation failed: \(String(describing: error))"
            )
        }
    }

    public func generateDescription(
        for frame: SampledFrame,
        prompt: String,
        config: GenerationConfig = .init(temperature: 0.2, topP: 0.9, maxTokens: 96)
    ) async throws -> String {
        try await generate(prompt: prompt, frames: [frame], config: config)
    }

    private nonisolated static func defaultModelDirectoryRoot() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }
}

/// VisionDescriber adapter that asks Qwen3-VL for one concise Chinese frame sentence.
public struct Qwen3VLDescriber: VisionDescriber {
    public static let defaultPrompt = "请用一句简短中文描述这张视频关键帧的主体、动作和场景。只输出一句话。"

    private let generator: any QwenVLFrameGenerating
    private let prompt: String
    private let maxFrameCount: Int
    private let maxFrameBytes: Int
    private let generationConfig: GenerationConfig

    public init(
        model: ModelIdentity = ModelCatalog.qwen3VL_4B_4bit,
        modelDirectoryRoot: URL? = nil,
        prompt: String = Qwen3VLDescriber.defaultPrompt,
        maxFrameCount: Int = 8,
        maxFrameBytes: Int = 8_000_000,
        generationConfig: GenerationConfig = .init(temperature: 0.2, topP: 0.9, maxTokens: 96)
    ) {
        self.init(
            generator: QwenVLContainer(model: model, modelDirectoryRoot: modelDirectoryRoot),
            prompt: prompt,
            maxFrameCount: maxFrameCount,
            maxFrameBytes: maxFrameBytes,
            generationConfig: generationConfig
        )
    }

    public init(
        generator: any QwenVLFrameGenerating,
        prompt: String = Qwen3VLDescriber.defaultPrompt,
        maxFrameCount: Int = 8,
        maxFrameBytes: Int = 8_000_000,
        generationConfig: GenerationConfig = .init(temperature: 0.2, topP: 0.9, maxTokens: 96)
    ) {
        self.generator = generator
        self.prompt = prompt
        self.maxFrameCount = max(0, maxFrameCount)
        self.maxFrameBytes = max(1, maxFrameBytes)
        self.generationConfig = generationConfig
    }

    public func describe(_ frames: [SampledFrame]) async throws -> [FrameDescription] {
        let preparedFrames = try prepare(frames)
        guard !preparedFrames.isEmpty else {
            return []
        }

        var descriptions: [FrameDescription] = []
        descriptions.reserveCapacity(preparedFrames.count)

        for frame in preparedFrames {
            do {
                let output = try await generator.generateDescription(
                    for: frame,
                    prompt: prompt,
                    config: generationConfig
                )
                let description = try Self.normalizedDescription(output, timestamp: frame.timestampSeconds)
                descriptions.append(FrameDescription(
                    timestampSeconds: frame.timestampSeconds,
                    description: description
                ))
            } catch let error as VideoUnderstandingError {
                throw error
            } catch {
                Log.frameVision.error(
                    "Qwen3-VL describe failed at \(frame.timestampSeconds, privacy: .public)s: \(String(describing: error), privacy: .public)"
                )
                throw VideoUnderstandingError.visionUnavailable(
                    "Qwen3-VL describe failed at \(frame.timestampSeconds)s: \(String(describing: error))"
                )
            }
        }

        return descriptions
    }

    private func prepare(_ frames: [SampledFrame]) throws -> [SampledFrame] {
        guard maxFrameCount > 0 else {
            return []
        }

        return try frames
            .sorted { lhs, rhs in lhs.timestampSeconds < rhs.timestampSeconds }
            .prefix(maxFrameCount)
            .map { frame in
                guard frame.timestampSeconds.isFinite, frame.timestampSeconds >= 0 else {
                    throw VideoUnderstandingError.visionUnavailable(
                        "Qwen3-VL frame has an invalid timestamp: \(frame.timestampSeconds)."
                    )
                }

                guard !frame.jpegData.isEmpty else {
                    throw VideoUnderstandingError.visionUnavailable(
                        "Qwen3-VL frame at \(frame.timestampSeconds)s has empty JPEG data."
                    )
                }

                guard frame.jpegData.count <= maxFrameBytes else {
                    throw VideoUnderstandingError.visionUnavailable(
                        "Qwen3-VL frame at \(frame.timestampSeconds)s exceeds \(maxFrameBytes) bytes."
                    )
                }

                guard frame.jpegData.starts(with: [0xFF, 0xD8]) else {
                    throw VideoUnderstandingError.visionUnavailable(
                        "Qwen3-VL frame at \(frame.timestampSeconds)s is not JPEG data."
                    )
                }

                return frame
            }
    }

    private static func normalizedDescription(_ output: String, timestamp: Double) throws -> String {
        let firstLine = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""

        guard !firstLine.isEmpty else {
            throw VideoUnderstandingError.visionUnavailable(
                "Qwen3-VL returned an empty description for frame at \(timestamp)s."
            )
        }

        return firstLine
    }
}

protocol QwenVLRuntimeLoading: Sendable {
    func load(_ model: ModelIdentity) async throws -> any QwenVLSession
    func clearCache() async
}

protocol QwenVLSession: Sendable {
    func generate(
        prompt: String,
        frames: [SampledFrame],
        config: GenerationConfig
    ) async throws -> String
}

extension QwenVLSession {
    func generateDescription(
        for frame: SampledFrame,
        prompt: String,
        config: GenerationConfig
    ) async throws -> String
    {
        try await generate(prompt: prompt, frames: [frame], config: config)
    }
}

struct RealQwenVLRuntime: QwenVLRuntimeLoading {
    private static let manifestFileName = ".engram-model.json"

    private let modelDirectoryRoot: URL
    private let tokenizerLoader: any TokenizerLoader

    init(
        modelDirectoryRoot: URL,
        tokenizerLoader: any TokenizerLoader = QwenVLTransformersTokenizerLoader()
    ) {
        self.modelDirectoryRoot = modelDirectoryRoot
        self.tokenizerLoader = tokenizerLoader
    }

    func load(_ model: ModelIdentity) async throws -> any QwenVLSession {
        let directory = try resolvedModelDirectory(for: model)
        guard try containsPayloadFile(in: directory) else {
            throw VideoUnderstandingError.visionUnavailable(
                "Qwen3-VL model artifacts missing at \(directory.path). Download or import the model first."
            )
        }

        let container = try await VLMModelFactory.shared.loadContainer(
            from: directory,
            using: tokenizerLoader
        )
        return RealQwenVLSession(container: container)
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

struct RealQwenVLSession: QwenVLSession {
    let container: ModelContainer

    func generate(
        prompt: String,
        frames: [SampledFrame],
        config: GenerationConfig
    ) async throws -> String {
        let images = try frames.map { frame in
            guard let image = CIImage(data: frame.jpegData) else {
                throw VideoUnderstandingError.visionUnavailable(
                    "Qwen3-VL could not decode JPEG frame at \(frame.timestampSeconds)s."
                )
            }

            return image
        }

        let userInput = UserInput(chat: [
            .user(prompt, images: images.map { .ciImage($0) })
        ])
        let input = try await container.prepare(input: userInput)
        let parameters = GenerateParameters(
            maxTokens: config.maxTokens,
            temperature: Float(config.temperature),
            topP: Float(config.topP)
        )
        let stream = try await container.generate(input: input, parameters: parameters)

        var output = ""
        for await generation in stream {
            if Task.isCancelled {
                throw CancellationError()
            }

            switch generation {
            case .chunk(let text):
                output += text
            case .info:
                return output
            case .toolCall:
                Log.frameVision.warning("Qwen3-VL emitted a tool call; frame describer ignores tool calls")
            }
        }

        return output
    }
}

struct QwenVLTransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return QwenVLTokenizersTokenizerBridge(upstream: tokenizer)
    }
}

struct QwenVLTokenizersTokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
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
