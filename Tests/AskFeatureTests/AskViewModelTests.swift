import EngineKit
import RAGCore
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
@Test func askViewModelHidesQwenThinkingTagsFromFinishedResponse() async {
    let engine = FakeEngine(events: [
        .token("<think>\n"),
        .token("internal scratchpad"),
        .token("\n</think>\n\nVisible answer"),
        .finished(.stop, GenerationMetrics(
            firstTokenLatencyMillis: nil,
            tokensPerSecond: nil,
            outputTokenCount: 2
        )),
    ])
    let viewModel = AskViewModel(engine: engine, model: testModel)

    guard let task = viewModel.send("Hello?") else {
        Issue.record("Expected send to start")
        return
    }

    await task.value

    #expect(viewModel.messages[1].text == "Visible answer")
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

@MainActor
@Test func askViewModelShortCircuitsZeroHitsWithoutCallingLLM() async {
    let engine = FakeEngine(events: [
        .token("should not stream"),
    ])
    let viewModel = AskViewModel(
        engine: engine,
        model: testModel,
        retriever: FakeRetriever(results: [])
    )

    guard let task = viewModel.send("Where is this?") else {
        Issue.record("Expected send to start")
        return
    }

    await task.value

    #expect(viewModel.messages.map(\.text) == ["Where is this?", AskViewModel.noSupportingClipsMessage])
    #expect(await engine.loadedModelIDs().isEmpty)
    #expect(await engine.generateCallCount() == 0)
}

@MainActor
@Test func askViewModelShortCircuitsLowScoreWithoutCallingLLM() async {
    let engine = FakeEngine(events: [
        .token("should not stream"),
    ])
    let lowScore = RetrievedChunk(
        chunk: testChunk("low", text: "Weak evidence"),
        score: 0.001,
        citation: CitationRef(chunkID: "low", clipID: "clip-low", snippet: "Weak evidence")
    )
    let viewModel = AskViewModel(
        engine: engine,
        model: testModel,
        retriever: FakeRetriever(results: [lowScore])
    )

    guard let task = viewModel.send("Weak?") else {
        Issue.record("Expected send to start")
        return
    }

    await task.value

    #expect(viewModel.messages[1].text == AskViewModel.noSupportingClipsMessage)
    #expect(await engine.loadedModelIDs().isEmpty)
    #expect(await engine.generateCallCount() == 0)
}

@MainActor
@Test func askViewModelBuildsNumberedGroundedPromptAndPropagatesCitations() async {
    let metrics = GenerationMetrics(firstTokenLatencyMillis: 3, tokensPerSecond: 4, outputTokenCount: 1)
    let engine = FakeEngine(events: [
        .token("Grounded answer [1]"),
        .finished(.stop, metrics),
    ])
    let citations = [
        RetrievedChunk(
            chunk: testChunk("one", text: "First retrieved chunk"),
            score: 0.04,
            citation: CitationRef(chunkID: "one", clipID: "clip-one", snippet: "First")
        ),
        RetrievedChunk(
            chunk: testChunk("two", text: "Second retrieved chunk"),
            score: 0.03,
            citation: CitationRef(chunkID: "two", clipID: "clip-two", snippet: "Second")
        ),
    ]
    let viewModel = AskViewModel(
        engine: engine,
        model: testModel,
        retriever: FakeRetriever(results: citations)
    )

    guard let task = viewModel.send("What did I save?") else {
        Issue.record("Expected send to start")
        return
    }

    await task.value

    let prompt = await engine.lastPrompt().joined(separator: "\n")
    #expect(prompt.contains("仅基于这些内容回答，引用编号"))
    #expect(prompt.contains("拆解内容:"))
    #expect(prompt.contains("[1] First retrieved chunk"))
    #expect(prompt.contains("[2] Second retrieved chunk"))
    #expect(prompt.contains("What did I save?"))
    #expect(viewModel.messages[1].text == "Grounded answer [1]")
    #expect(viewModel.messages[1].citations == citations.map(\.citation))
}

@MainActor
@Test func askViewModelClearsCitationsWhenGroundedAnswerDeclinesSupport() async {
    let engine = FakeEngine(events: [
        .token("<think>\n</think>\n\n"),
        .token("\(AskViewModel.noSupportingClipsMessage)。"),
        .finished(.stop, GenerationMetrics(
            firstTokenLatencyMillis: 3,
            tokensPerSecond: 4,
            outputTokenCount: 1
        )),
    ])
    let retrieved = RetrievedChunk(
        chunk: testChunk("one", text: "This domain is for use in documentation examples."),
        score: 0.04,
        citation: CitationRef(
            chunkID: "one",
            clipID: "clip-one",
            snippet: "This domain is for use in documentation examples."
        )
    )
    let viewModel = AskViewModel(
        engine: engine,
        model: testModel,
        retriever: FakeRetriever(results: [retrieved])
    )

    guard let task = viewModel.send("你是什么模型") else {
        Issue.record("Expected send to start")
        return
    }

    await task.value

    #expect(viewModel.messages[1].text == "\(AskViewModel.noSupportingClipsMessage)。")
    #expect(viewModel.messages[1].citations.isEmpty)
}

@MainActor
@Test func askViewModelTrimsRetrievedChunksToTokenBudget() async {
    let engine = FakeEngine(events: [
        .finished(.stop, GenerationMetrics(
            firstTokenLatencyMillis: nil,
            tokensPerSecond: nil,
            outputTokenCount: 0
        )),
    ])
    let hugeText = String(repeating: "Long retrieved context. ", count: 80)
    let retrieved = [
        RetrievedChunk(
            chunk: testChunk("kept", text: "Short evidence"),
            score: 0.04,
            citation: CitationRef(chunkID: "kept", clipID: "clip-kept", snippet: "Short evidence")
        ),
        RetrievedChunk(
            chunk: testChunk("trimmed", text: hugeText),
            score: 0.03,
            citation: CitationRef(chunkID: "trimmed", clipID: "clip-trimmed", snippet: "Long")
        ),
    ]
    let viewModel = AskViewModel(
        engine: engine,
        model: testModel,
        retriever: FakeRetriever(results: retrieved),
        retrievalConfiguration: AskRetrievalConfiguration(promptTokenBudget: 280)
    )

    guard let task = viewModel.send("Budget?") else {
        Issue.record("Expected send to start")
        return
    }

    await task.value

    let prompt = await engine.lastPrompt().joined(separator: "\n")
    #expect(prompt.contains("[1] Short evidence"))
    #expect(!prompt.contains("Long retrieved context"))
    #expect(viewModel.messages[1].citations == [retrieved[0].citation])
    #expect(await engine.countTokenInputs().count >= 2)
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
    private var generateCalls = 0
    private var tokenInputs: [String] = []

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
        generateCalls += 1
        capturedRequest = request

        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func countTokens(in text: String) async throws -> Int {
        tokenInputs.append(text)
        return text.count
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

    func generateCallCount() -> Int {
        generateCalls
    }

    func countTokenInputs() -> [String] {
        tokenInputs
    }
}

private actor FakeRetriever: Retriever {
    private let results: [RetrievedChunk]

    init(results: [RetrievedChunk]) {
        self.results = results
    }

    func retrieve(question: String, topK: Int) async throws -> [RetrievedChunk] {
        Array(results.prefix(topK))
    }
}

private func testChunk(_ id: String, text: String) -> Chunk {
    Chunk(id: id, clipID: "clip-\(id)", text: text, indexInClip: 0, preview: text)
}
