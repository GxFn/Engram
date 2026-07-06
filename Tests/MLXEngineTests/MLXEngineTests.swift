import EngineKit
import Foundation
import Testing
@testable import MLXEngine

@Test func mlxLoadFailsExplicitlyOnIOSSimulator() async throws {
    #if os(iOS) && targetEnvironment(simulator)
    let engine = MLXEngine()
    let model = ModelIdentity(
        id: "mlx-community/Qwen3-4B-4bit",
        family: "Qwen3",
        quantization: "4bit",
        contextLength: 32768,
        estimatedMemoryBytes: 2_300_000_000
    )

    do {
        try await engine.load(model)
        Issue.record("Expected iOS simulator MLX load to throw")
    } catch EngineError.notImplemented(let message) {
        #expect(message == "simulator unsupported - use a device or macOS")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #endif
}

@Test func mlxGenerationMapsTextAndCompletionMetrics() async throws {
    let session = FakeSession(
        events: [
            .text("Hel"),
            .text("lo"),
            .finished(.init(reason: .length, outputTokenCount: 2, tokensPerSecond: 42)),
        ],
        tokenCount: 5
    )
    let engine = MLXEngine(runtime: FakeRuntime(session: session))
    try await engine.load(testModel)

    let events = try await collectEvents(
        from: await engine.generate(
            GenerationRequest(
                messages: [.init(role: .user, content: "Hello")],
                config: .init(temperature: 0.2, topP: 0.8, maxTokens: 8)
            )
        )
    )

    #expect(events.count == 3)
    #expect(tokenText(events[0]) == "Hel")
    #expect(tokenText(events[1]) == "lo")

    let finish = finished(events[2])
    #expect(finish?.reason == .length)
    #expect(finish?.metrics.outputTokenCount == 2)
    #expect(finish?.metrics.tokensPerSecond == 42)
    #expect(finish?.metrics.firstTokenLatencyMillis != nil)
}

@Test func mlxGenerationMapsRuntimeCancellationToFinishedEvent() async throws {
    let session = FakeSession(
        events: [.text("draft")],
        terminal: .cancelled,
        tokenCount: 1
    )
    let engine = MLXEngine(runtime: FakeRuntime(session: session))
    try await engine.load(testModel)

    let events = try await collectEvents(
        from: await engine.generate(
            GenerationRequest(messages: [.init(role: .user, content: "Stop")])
        )
    )

    #expect(events.count == 2)
    #expect(tokenText(events[0]) == "draft")
    let finish = finished(events[1])
    #expect(finish?.reason == .cancelled)
    #expect(finish?.metrics.outputTokenCount == 1)
    #expect(finish?.metrics.firstTokenLatencyMillis != nil)
}

@Test func mlxGenerateAndCountTokensFailWhenNoModelIsLoaded() async throws {
    let engine = MLXEngine(runtime: FakeRuntime(session: FakeSession(events: [], tokenCount: 0)))

    do {
        _ = try await collectEvents(
            from: await engine.generate(
                GenerationRequest(messages: [.init(role: .user, content: "Hello")])
            )
        )
        Issue.record("Expected generation without a loaded model to fail")
    } catch EngineError.modelNotLoaded {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    do {
        _ = try await engine.countTokens(in: "Hello")
        Issue.record("Expected countTokens without a loaded model to fail")
    } catch EngineError.modelNotLoaded {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func mlxCountTokensUsesLoadedRuntimeSession() async throws {
    let engine = MLXEngine(runtime: FakeRuntime(session: FakeSession(events: [], tokenCount: 7)))
    try await engine.load(testModel)

    #expect(try await engine.countTokens(in: "one two three") == 7)
}

@Test func mlxChatMessagesPreserveEngineKitRolesAndContent() {
    let messages = RealMLXEngineSession.chatMessages(from: [
        .init(role: .system, content: "policy"),
        .init(role: .user, content: "question"),
        .init(role: .assistant, content: "answer"),
    ])

    #expect(messages.map(\.role.rawValue) == ["system", "user", "assistant"])
    #expect(messages.map(\.content) == ["policy", "question", "answer"])
}

@Test func mlxRuntimeResolvesCanonicalModelDirectoryWhenPayloadExists() throws {
    let root = try makeTemporaryModelRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    let modelDirectory = try makeModelDirectory(for: testModel, in: root)
    try writeFile(named: "weights.safetensors", bytes: 1, in: modelDirectory)

    let runtime = RealMLXEngineRuntime(modelDirectoryRoot: root)

    #expect(
        try runtime.resolvedModelDirectory(for: testModel).resolvingSymlinksInPath()
            == modelDirectory.resolvingSymlinksInPath()
    )
}

@Test func mlxRuntimeResolvesManifestBackedModelDirectoryWhenPayloadExists() throws {
    let root = try makeTemporaryModelRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    let importedDirectory = root.appendingPathComponent("Imported/custom-model", isDirectory: true)
    try FileManager.default.createDirectory(at: importedDirectory, withIntermediateDirectories: true)
    try writeManifest(for: testModel, in: importedDirectory)
    try writeFile(named: "weights.safetensors", bytes: 1, in: importedDirectory)

    let runtime = RealMLXEngineRuntime(modelDirectoryRoot: root)

    #expect(
        try runtime.resolvedModelDirectory(for: testModel).resolvingSymlinksInPath()
            == importedDirectory.resolvingSymlinksInPath()
    )
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ENGRAM_SMOKE"] == "1"))
func mlxMacOSSmokeGeneratesWithLocalModelWhenEnabled() async throws {
    #if os(macOS)
    let root = ProcessInfo.processInfo.environment["ENGRAM_SMOKE_MODELS_DIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    let engine = MLXEngine(modelDirectoryRoot: root)
    let model = ModelIdentity(
        id: ProcessInfo.processInfo.environment["ENGRAM_SMOKE_MODEL_ID"] ?? "mlx-community/Qwen3-1.7B-4bit",
        family: "qwen3",
        quantization: "4bit",
        contextLength: 32_768,
        estimatedMemoryBytes: 1_100_000_000
    )

    try await engine.load(model)
    let stream = await engine.generate(
        GenerationRequest(
            messages: [.init(role: .user, content: "Write one short sentence about local memory.")],
            config: .init(temperature: 0.2, topP: 0.9, maxTokens: 20)
        )
    )

    var output = ""
    var metrics: GenerationMetrics?
    for try await event in stream {
        switch event {
        case .token(let text):
            output += text
        case .finished(_, let generationMetrics):
            metrics = generationMetrics
        }
    }

    #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect((metrics?.outputTokenCount ?? 0) > 0)
    #expect(metrics?.tokensPerSecond != nil)
    await engine.unload()
    #endif
}

private let testModel = ModelIdentity(
    id: "test/model",
    family: "test",
    quantization: "4bit",
    contextLength: 128,
    estimatedMemoryBytes: 64
)

private struct FakeRuntime: MLXEngineRuntime {
    let session: any MLXEngineSession

    func load(_ model: ModelIdentity) async throws -> any MLXEngineSession {
        session
    }

    func clearCache() async {}
}

private final class FakeSession: MLXEngineSession, @unchecked Sendable {
    enum Terminal: Sendable {
        case finished
        case cancelled
    }

    private let events: [MLXEngineRuntimeEvent]
    private let terminal: Terminal
    private let tokenCount: Int

    init(
        events: [MLXEngineRuntimeEvent],
        terminal: Terminal = .finished,
        tokenCount: Int
    ) {
        self.events = events
        self.terminal = terminal
        self.tokenCount = tokenCount
    }

    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<MLXEngineRuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }

            switch terminal {
            case .finished:
                continuation.finish()
            case .cancelled:
                continuation.finish(throwing: CancellationError())
            }
        }
    }

    func countTokens(in text: String) async throws -> Int {
        tokenCount
    }
}

private func collectEvents(from stream: AsyncThrowingStream<GenerationEvent, Error>) async throws -> [GenerationEvent] {
    var events: [GenerationEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private func tokenText(_ event: GenerationEvent) -> String? {
    if case .token(let text) = event {
        return text
    }

    return nil
}

private func finished(_ event: GenerationEvent) -> (reason: FinishReason, metrics: GenerationMetrics)? {
    if case .finished(let reason, let metrics) = event {
        return (reason, metrics)
    }

    return nil
}

private func makeTemporaryModelRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramMLXEngineTests-\(UUID().uuidString)", isDirectory: true)
    let modelsDirectory = root.appendingPathComponent("Models", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    return modelsDirectory
}

private func makeModelDirectory(for model: ModelIdentity, in modelsDirectory: URL) throws -> URL {
    let modelDirectory = model.id.split(separator: "/").reduce(modelsDirectory) { url, component in
        url.appendingPathComponent(String(component), isDirectory: true)
    }

    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    return modelDirectory
}

private func writeFile(named name: String, bytes: Int, in directory: URL) throws {
    let data = Data(repeating: 0x41, count: bytes)
    try data.write(to: directory.appendingPathComponent(name, isDirectory: false))
}

private func writeManifest(for model: ModelIdentity, in directory: URL) throws {
    let data = try JSONEncoder().encode(model)
    try data.write(to: directory.appendingPathComponent(".engram-model.json", isDirectory: false))
}
