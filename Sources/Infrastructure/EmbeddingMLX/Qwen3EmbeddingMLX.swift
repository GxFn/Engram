import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import RAGCore
import Tokenizers

/// Local Qwen3-Embedding adapter. It only reads already-present model payloads
/// from the model directory; downloads remain owned by ModelStore/Settings.
public actor Qwen3EmbeddingMLX: EmbeddingEngine {
    public static let defaultModelID = "mlx-community/Qwen3-Embedding-0.6B-4bit"
    public static let fallbackModelID = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
    public static let outputDimension = 1024

    public nonisolated let metadata: EmbeddingEngineMetadata

    private let runtime: any Qwen3EmbeddingRuntime
    private var session: (any Qwen3EmbeddingSession)?

    public init(modelDirectoryRoot: URL? = nil) {
        self.init(
            runtime: RealQwen3EmbeddingRuntime(
                modelID: Self.defaultModelID,
                fallbackModelID: Self.fallbackModelID,
                modelDirectoryRoot: modelDirectoryRoot ?? Self.defaultModelDirectoryRoot()
            ),
            modelID: Self.defaultModelID
        )
    }

    init(runtime: any Qwen3EmbeddingRuntime, modelID: String = Qwen3EmbeddingMLX.defaultModelID) {
        self.runtime = runtime
        self.metadata = EmbeddingEngineMetadata(
            id: "qwen3-embedding-mlx",
            displayName: "Qwen3 Embedding MLX",
            dimension: Self.outputDimension,
            modelIdentifier: modelID
        )
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw RetrievalError.invalidEmbeddingInput("Qwen3EmbeddingMLX received empty text")
        }

        let activeSession = try await loadSessionIfNeeded()
        let vectors = try await activeSession.embed(texts)
        try validate(vectors, expectedCount: texts.count)
        return vectors
    }

    private func loadSessionIfNeeded() async throws -> any Qwen3EmbeddingSession {
        if let session {
            return session
        }

        let loaded = try await runtime.load()
        session = loaded
        return loaded
    }

    private nonisolated func validate(_ vectors: [[Float]], expectedCount: Int) throws {
        guard vectors.count == expectedCount else {
            throw RetrievalError.invalidEmbeddingOutput(
                engineID: metadata.id,
                reason: "expected \(expectedCount) vectors, got \(vectors.count)"
            )
        }

        for vector in vectors {
            guard vector.count == Self.outputDimension else {
                throw RetrievalError.invalidEmbeddingOutput(
                    engineID: metadata.id,
                    reason: "expected dimension \(Self.outputDimension), got \(vector.count)"
                )
            }
            guard vector.allSatisfy({ $0.isFinite }) else {
                throw RetrievalError.invalidEmbeddingOutput(
                    engineID: metadata.id,
                    reason: "embedding vector contains non-finite values"
                )
            }
        }
    }

    private nonisolated static func defaultModelDirectoryRoot() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }
}

public typealias EmbeddingMLXEngine = Qwen3EmbeddingMLX

protocol Qwen3EmbeddingRuntime: Sendable {
    func load() async throws -> any Qwen3EmbeddingSession
}

protocol Qwen3EmbeddingSession: Sendable {
    func embed(_ texts: [String]) async throws -> [[Float]]
}

struct RealQwen3EmbeddingRuntime: Qwen3EmbeddingRuntime {
    private static let manifestFileName = ".engram-model.json"

    let modelID: String
    let fallbackModelID: String
    let modelDirectoryRoot: URL
    let tokenizerLoader: any TokenizerLoader

    init(
        modelID: String,
        fallbackModelID: String,
        modelDirectoryRoot: URL,
        tokenizerLoader: any TokenizerLoader = EmbeddingTransformersTokenizerLoader()
    ) {
        self.modelID = modelID
        self.fallbackModelID = fallbackModelID
        self.modelDirectoryRoot = modelDirectoryRoot
        self.tokenizerLoader = tokenizerLoader
    }

    func load() async throws -> any Qwen3EmbeddingSession {
        #if os(iOS) && targetEnvironment(simulator)
        throw RetrievalError.embeddingUnavailable(
            engineID: "qwen3-embedding-mlx",
            reason: "iOS Simulator cannot run MLX embedding models; use a device or macOS"
        )
        #else
        let directory = try resolvedModelDirectory()
        guard try containsPayloadFile(in: directory) else {
            throw RetrievalError.embeddingModelNotDownloaded(
                modelID: modelID,
                expectedPath: directory.path
            )
        }

        do {
            let container = try await EmbedderModelFactory.shared.loadContainer(
                from: directory,
                using: tokenizerLoader
            )
            return RealQwen3EmbeddingSession(container: container)
        } catch let error as RetrievalError {
            throw error
        } catch {
            throw RetrievalError.embeddingModelLoadFailed(
                modelID: modelID,
                reason: String(describing: error)
            )
        }
        #endif
    }

    func resolvedModelDirectory() throws -> URL {
        for candidateID in [modelID, fallbackModelID] {
            let canonicalDirectory = canonicalModelDirectory(for: candidateID)
            if try containsPayloadFile(in: canonicalDirectory) {
                return canonicalDirectory
            }
        }

        return try manifestBackedDirectory()
            ?? canonicalModelDirectory(for: modelID)
    }

    private func canonicalModelDirectory(for modelID: String) -> URL {
        modelID.split(separator: "/").reduce(modelDirectoryRoot) { url, component in
            url.appendingPathComponent(String(component), isDirectory: true)
        }
    }

    private func manifestBackedDirectory() throws -> URL? {
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
            let manifest = try JSONDecoder().decode(EmbeddingModelManifest.self, from: data)
            if [modelID, fallbackModelID].contains(manifest.id), try containsPayloadFile(in: directory) {
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

struct RealQwen3EmbeddingSession: Qwen3EmbeddingSession {
    let container: EmbedderModelContainer

    func embed(_ texts: [String]) async throws -> [[Float]] {
        await container.perform { context in
            let encodedInputs = texts.map {
                context.tokenizer.encode(text: $0, addSpecialTokens: true)
            }
            let padToken = context.tokenizer.eosTokenId ?? 0
            let maxLength = max(1, encodedInputs.map(\.count).max() ?? 1)
            let paddedInputs = encodedInputs.map { tokens in
                tokens + Array(repeating: padToken, count: maxLength - tokens.count)
            }

            let padded = stacked(paddedInputs.map { MLXArray($0) })
            let attentionMask = padded .!= padToken
            let tokenTypes = MLXArray.zeros(like: padded)
            let output = context.model(
                padded,
                positionIds: nil,
                tokenTypeIds: tokenTypes,
                attentionMask: attentionMask
            )
            let pooled = context.pooling(
                output,
                mask: attentionMask,
                normalize: true,
                applyLayerNorm: true
            )
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }
}

private struct EmbeddingModelManifest: Decodable {
    let id: String
}
