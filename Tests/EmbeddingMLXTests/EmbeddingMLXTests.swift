import Foundation
import RAGCore
import Testing
@testable import EmbeddingMLX

@Test func appleEmbeddingMetadataAndEmptyBatchAreStable() async throws {
    let runtime = FakeAppleRuntime(
        dimension: 4,
        modelIdentifier: "fake-apple",
        vectors: ["Hello": [1, 0, 0, 0]]
    )
    let engine = AppleContextualEmbedding(runtime: runtime)

    #expect(engine.metadata.id == "apple-natural-language-contextual")
    #expect(engine.metadata.dimension == 4)
    #expect(engine.dimension == 4)
    #expect(try await engine.embed([]).isEmpty)
}

@Test func appleEmbeddingPreservesInputOrderAndOutputCount() async throws {
    let engine = AppleContextualEmbedding(
        runtime: FakeAppleRuntime(
            dimension: 4,
            modelIdentifier: "fake-apple",
            vectors: [
                "first": [1, 0, 0, 0],
                "second": [0, 1, 0, 0],
            ]
        )
    )

    let vectors = try await engine.embed(["first", "second"])

    #expect(vectors == [[1, 0, 0, 0], [0, 1, 0, 0]])
}

@Test func appleEmbeddingReportsUnavailableInsteadOfFallbackVectors() async throws {
    let engine = AppleContextualEmbedding(
        runtime: FakeAppleRuntime(
            dimension: 4,
            modelIdentifier: "fake-apple",
            vectors: [:],
            error: RetrievalError.embeddingUnavailable(
                engineID: "apple-natural-language-contextual",
                reason: "assets unavailable"
            )
        )
    )

    do {
        _ = try await engine.embed(["missing"])
        Issue.record("Expected unavailable Apple embedding to throw")
    } catch RetrievalError.embeddingUnavailable(let engineID, let reason) {
        #expect(engineID == "apple-natural-language-contextual")
        #expect(reason == "assets unavailable")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func qwenEmbeddingMetadataAndEmptyBatchAreStable() async throws {
    let engine = Qwen3EmbeddingMLX(
        runtime: FakeQwenRuntime(session: FakeQwenSession(vectors: []))
    )

    #expect(engine.metadata.id == "qwen3-embedding-mlx")
    #expect(engine.metadata.dimension == 1024)
    #expect(engine.metadata.modelIdentifier == Qwen3EmbeddingMLX.defaultModelID)
    #expect(engine.dimension == 1024)
    #expect(try await engine.embed([]).isEmpty)
}

@Test func qwenEmbeddingPreservesInputOrderAndOutputCount() async throws {
    let first = Array(repeating: Float(0.25), count: Qwen3EmbeddingMLX.outputDimension)
    let second = Array(repeating: Float(0.5), count: Qwen3EmbeddingMLX.outputDimension)
    let engine = Qwen3EmbeddingMLX(
        runtime: FakeQwenRuntime(session: FakeQwenSession(vectors: [first, second]))
    )

    let vectors = try await engine.embed(["first", "second"])

    #expect(vectors.count == 2)
    #expect(vectors[0] == first)
    #expect(vectors[1] == second)
}

@Test func qwenEmbeddingRejectsInvalidDimension() async throws {
    let engine = Qwen3EmbeddingMLX(
        runtime: FakeQwenRuntime(session: FakeQwenSession(vectors: [[1, 2, 3]]))
    )

    do {
        _ = try await engine.embed(["bad dimension"])
        Issue.record("Expected invalid dimension to throw")
    } catch RetrievalError.invalidEmbeddingOutput(let engineID, let reason) {
        #expect(engineID == "qwen3-embedding-mlx")
        #expect(reason.contains("expected dimension 1024"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func qwenEmbeddingWithoutLocalPayloadReportsNotDownloaded() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let engine = Qwen3EmbeddingMLX(modelDirectoryRoot: temporaryRoot)

    do {
        _ = try await engine.embed(["local model required"])
        Issue.record("Expected missing Qwen3 model payload to throw")
    } catch RetrievalError.embeddingModelNotDownloaded(let modelID, let expectedPath) {
        #expect(modelID == Qwen3EmbeddingMLX.defaultModelID)
        #expect(expectedPath.contains("Qwen3-Embedding-0.6B-4bit"))
    } catch RetrievalError.embeddingUnavailable(let engineID, let reason) {
        #if os(iOS) && targetEnvironment(simulator)
        #expect(engineID == "qwen3-embedding-mlx")
        #expect(reason.contains("iOS Simulator"))
        #else
        Issue.record("Unexpected platform unavailability: \(engineID) \(reason)")
        #endif
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private struct FakeAppleRuntime: AppleContextualEmbeddingRuntime {
    let dimension: Int
    let modelIdentifier: String
    let vectors: [String: [Float]]
    var error: RetrievalError?

    func embed(_ text: String) throws -> [Float] {
        if let error {
            throw error
        }
        guard let vector = vectors[text] else {
            throw RetrievalError.invalidEmbeddingInput("missing fake vector for \(text)")
        }
        return vector
    }
}

private struct FakeQwenRuntime: Qwen3EmbeddingRuntime {
    let session: any Qwen3EmbeddingSession

    func load() async throws -> any Qwen3EmbeddingSession {
        session
    }
}

private struct FakeQwenSession: Qwen3EmbeddingSession {
    let vectors: [[Float]]

    func embed(_ texts: [String]) async throws -> [[Float]] {
        vectors
    }
}
