import EngineKit
import Testing
@testable import AskFeature

@MainActor
@Test func askViewModelStreamsTokensAndStoresMetrics() async {
    let metrics = GenerationMetrics(
        firstTokenLatencyMillis: 12,
        tokensPerSecond: 33.5,
        outputTokenCount: 2
    )
    let engine = FakeEngine(events: [
        .token("Hel"),
        .token("lo"),
        .finished(.stop, metrics),
    ])
    let viewModel = AskViewModel(engine: engine, model: testModel)

    guard let task = viewModel.send("  Hello?  ") else {
        Issue.record("Expected send to start a generation task")
        return
    }

    await task.value

    #expect(viewModel.isGenerating == false)
    #expect(viewModel.messages.count == 2)
    #expect(viewModel.messages[0].role == .user)
    #expect(viewModel.messages[0].text == "Hello?")
    #expect(viewModel.messages[1].role == .assistant)
    #expect(viewModel.messages[1].text == "Hello")
    #expect(viewModel.messages[1].finishReason == .stop)
    #expect(viewModel.messages[1].metrics?.outputTokenCount == 2)
    #expect(await engine.loadedModelIDs() == [testModel.id])
    #expect(await engine.lastPrompt() == ["Hello?"])
}

@MainActor
@Test func askViewModelSurfacesSimulatorUnsupportedLoadFailure() async {
    let engine = FakeEngine(
        loadError: EngineError.notImplemented("simulator unsupported - use a device or macOS"),
        events: []
    )
    let viewModel = AskViewModel(engine: engine, model: testModel)

    guard let task = viewModel.send("Hi") else {
        Issue.record("Expected send to start a generation task")
        return
    }

    await task.value

    #expect(viewModel.isGenerating == false)
    #expect(viewModel.messages.count == 2)
    #expect(viewModel.messages[1].finishReason == .error)
    #expect(viewModel.messages[1].errorMessage == "Simulator cannot run MLX. Use a device or macOS.")
    #expect(viewModel.messages[1].text == "Simulator cannot run MLX. Use a device or macOS.")
}

@MainActor
@Test func askViewModelIgnoresEmptyAndConcurrentSends() async {
    let engine = FakeEngine(events: [.finished(.stop, GenerationMetrics(
        firstTokenLatencyMillis: nil,
        tokensPerSecond: nil,
        outputTokenCount: 0
    ))])
    let viewModel = AskViewModel(engine: engine, model: testModel)

    #expect(viewModel.send("   ") == nil)

    guard let task = viewModel.send("One") else {
        Issue.record("Expected first send to start")
        return
    }

    #expect(viewModel.send("Two") == nil)
    await task.value
    #expect(viewModel.messages.map(\.text) == ["One", "No response."])
}

@MainActor
@Test func askViewModelUsesInjectedGenerationConfig() async {
    let config = GenerationConfig(temperature: 0.2, topP: 0.75, maxTokens: 64)
    let engine = FakeEngine(events: [.finished(.stop, GenerationMetrics(
        firstTokenLatencyMillis: nil,
        tokensPerSecond: nil,
        outputTokenCount: 0
    ))])
    let viewModel = AskViewModel(engine: engine, model: testModel, generationConfig: config)

    guard let task = viewModel.send("Config?") else {
        Issue.record("Expected send to start")
        return
    }

    await task.value

    #expect(await engine.lastConfig() == config)
}

private let testModel = ModelIdentity(
    id: "mlx-community/Qwen3-1.7B-4bit",
    family: "qwen3",
    quantization: "4bit",
    contextLength: 32_768,
    estimatedMemoryBytes: 1_100_000_000
)

private actor FakeEngine: LLMEngine {
    nonisolated let descriptor = EngineDescriptor(
        id: "fake",
        displayName: "Fake",
        kind: .mlx
    )

    private let loadError: Error?
    private let events: [GenerationEvent]
    private var loadedModels: [ModelIdentity] = []
    private var capturedRequest: GenerationRequest?

    init(loadError: Error? = nil, events: [GenerationEvent]) {
        self.loadError = loadError
        self.events = events
    }

    func load(_ model: ModelIdentity) async throws {
        if let loadError {
            throw loadError
        }

        loadedModels.append(model)
    }

    func unload() async {}

    func generate(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        capturedRequest = request

        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func countTokens(in text: String) async throws -> Int {
        text.count
    }

    func loadedModelIDs() -> [String] {
        loadedModels.map(\.id)
    }

    func lastPrompt() -> [String] {
        capturedRequest?.messages.map(\.content) ?? []
    }

    func lastConfig() -> GenerationConfig? {
        capturedRequest?.config
    }
}
