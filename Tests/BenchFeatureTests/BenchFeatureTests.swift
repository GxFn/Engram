import EngineKit
import Foundation
import MetricsKit
import RAGCore
import Testing
@testable import BenchFeature

@Test func promptSuiteLoadsBundledEightMixedPrompts() throws {
    let suite = try BenchPromptSuite.bundled()

    #expect(suite.prompts.count == 8)
    #expect(suite.prompts.contains { $0.text.contains("剪藏") })
    #expect(suite.prompts.contains { $0.text.contains("questions") })
}

@Test func benchAggregatorUsesMedianValuesAndPeakMemory() {
    let results = [
        result(ttft: 10, tokensPerSecond: 1, outputTokens: 4),
        result(ttft: 30, tokensPerSecond: 3, outputTokens: 8),
        result(ttft: 20, tokensPerSecond: 2, outputTokens: 6),
    ]

    let samples = BenchAggregator.samples(from: results, peakMemoryBytes: 512)
    let run = BenchRun(
        id: "run",
        startedAt: Date(timeIntervalSince1970: 0),
        engineID: "fake",
        modelID: "model",
        environment: BenchEnvironment(deviceModel: "device", thermalState: "nominal", lowPowerMode: false),
        samples: samples
    )

    #expect(run.sampleValue(.firstTokenLatencyMillis) == 20)
    #expect(run.sampleValue(.tokensPerSecond) == 2)
    #expect(run.sampleValue(.outputTokenCount) == 6)
    #expect(run.sampleValue(.peakMemoryBytes) == 512)
}

@Test func markdownExporterBuildsReadmeTableRows() {
    let run = BenchRun(
        id: "run",
        startedAt: Date(timeIntervalSince1970: 0),
        engineID: "fake",
        modelID: "mlx-community/test",
        environment: BenchEnvironment(deviceModel: "device", thermalState: "nominal", lowPowerMode: false),
        samples: [
            BenchSample(metric: BenchMetric.firstTokenLatencyMillis.rawValue, value: 20, unit: "ms"),
            BenchSample(metric: BenchMetric.tokensPerSecond.rawValue, value: 12.34, unit: "tok/s"),
            BenchSample(metric: BenchMetric.outputTokenCount.rawValue, value: 6, unit: "tokens"),
            BenchSample(metric: BenchMetric.peakMemoryBytes.rawValue, value: 1_048_576, unit: "bytes"),
        ]
    )

    let markdown = MarkdownExporter.table(for: [run])

    #expect(markdown.contains("| Date | Engine | Model |"))
    #expect(markdown.contains("fake"))
    #expect(markdown.contains("mlx-community/test"))
    #expect(markdown.contains("20 ms"))
    #expect(markdown.contains("1.0 MB"))
}

@Test func benchRunnerLoadsModelRunsRoundsAndAggregates() async throws {
    let engine = FakeBenchEngine(outcomes: [
        .finished(metrics(ttft: 10, tokensPerSecond: 1, outputTokens: 4)),
        .finished(metrics(ttft: 30, tokensPerSecond: 3, outputTokens: 8)),
        .finished(metrics(ttft: 20, tokensPerSecond: 2, outputTokens: 6)),
    ])
    let config = GenerationConfig(temperature: 0.1, topP: 0.8, maxTokens: 32)
    let runner = BenchRunner(
        engine: engine,
        model: testModel,
        config: config,
        promptSuite: BenchPromptSuite(prompts: [BenchPrompt(id: "p", text: "Prompt")]),
        rounds: 3,
        memorySampler: MemorySampler(readPhysFootprintBytes: { 2_097_152 }),
        thermalObserver: ThermalObserver {
            ThermalSnapshot(thermalState: .nominal, lowPowerMode: false)
        },
        idProvider: { "run-1" },
        dateProvider: { Date(timeIntervalSince1970: 0) },
        deviceModelProvider: { "TestDevice" }
    )

    let progressRecorder = ProgressRecorder()
    let run = try await runner.run { progress in
        await progressRecorder.record(progress)
    }
    let progressEvents = await progressRecorder.events

    #expect(run.id == "run-1")
    #expect(run.engineID == "fake")
    #expect(run.modelID == testModel.id)
    #expect(run.environment.deviceModel == "TestDevice")
    #expect(run.sampleValue(.firstTokenLatencyMillis) == 20)
    #expect(run.sampleValue(.tokensPerSecond) == 2)
    #expect(run.sampleValue(.outputTokenCount) == 6)
    #expect(run.sampleValue(.peakMemoryBytes) == 2_097_152)
    #expect(progressEvents.map(\.completedIterations) == [1, 2, 3])
    #expect(await engine.loadedModelIDs() == [testModel.id])
    #expect(await engine.capturedConfigs() == [config, config, config])
}

@Test func benchRunnerTreatsCancelledGenerationAsCancellation() async throws {
    let engine = FakeBenchEngine(outcomes: [.cancelled])
    let runner = BenchRunner(
        engine: engine,
        model: testModel,
        promptSuite: BenchPromptSuite(prompts: [BenchPrompt(id: "p", text: "Prompt")]),
        rounds: 1,
        memorySampler: MemorySampler(readPhysFootprintBytes: { 1 }),
        thermalObserver: ThermalObserver()
    )

    do {
        _ = try await runner.run()
        Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func retrievalEvalSuiteLoadsBundledFixtureAndValidatesGoldClips() throws {
    let suite = try RetrievalEvalSuite.bundled()

    #expect(suite.clips.count == 20)
    #expect(suite.chunks.count == 20)
    #expect(suite.questions.count == 24)
    #expect(suite.questions.allSatisfy { !$0.relevantClipIDs.isEmpty })
    #expect(suite.questions.contains { $0.id == "q-zero-hit-message" })
    #expect(suite.chunks.contains { $0.clipID == "clip-hybrid-rrf" })
}

@Test func retrievalEvalMetricsCalculateRecallAndMRR() {
    let relevant = ["clip-a", "clip-c"]
    let ranked = ["clip-b", "clip-c", "clip-d", "clip-a"]

    #expect(RetrievalEvalMetrics.recallAtK(
        relevantClipIDs: relevant,
        rankedClipIDs: ranked,
        k: 3
    ) == 0.5)
    #expect(RetrievalEvalMetrics.reciprocalRank(
        relevantClipIDs: relevant,
        rankedClipIDs: ranked
    ) == 0.5)
    #expect(RetrievalEvalMetrics.uniqueClipIDs(from: [
        RetrievalEvalHit(clipID: "clip-a", chunkID: "a-1", score: 1),
        RetrievalEvalHit(clipID: "clip-a", chunkID: "a-2", score: 0.9),
        RetrievalEvalHit(clipID: "clip-b", chunkID: "b-1", score: 0.8),
    ]) == ["clip-a", "clip-b"])
}

@Test func retrievalEvalClientRunsHybridVectorAndKeywordStrategiesAgainstFixture() async throws {
    let suite = try RetrievalEvalSuite.bundled()
    let client = RetrievalEvalClient.fixture(suite: suite)
    let question = try #require(suite.questions.first { $0.id == "q-hybrid-rrf" })

    let hybridHits = try await client.search(.hybrid, question.question, 8)
    let vectorHits = try await client.search(.vectorOnly, question.question, 8)
    let keywordHits = try await client.search(.keywordOnly, question.question, 8)

    #expect(RetrievalEvalMetrics.uniqueClipIDs(from: hybridHits).first == "clip-hybrid-rrf")
    #expect(RetrievalEvalMetrics.uniqueClipIDs(from: vectorHits).contains("clip-hybrid-rrf"))
    #expect(RetrievalEvalMetrics.uniqueClipIDs(from: keywordHits).contains("clip-hybrid-rrf"))
}

@Test func retrievalEvalRunnerReportsReadmeComparisonFromBundledFixture() async throws {
    let runner = try RetrievalEvalRunner.bundledFixture(
        idProvider: { "retrieval-run" },
        dateProvider: { Date(timeIntervalSince1970: 0) }
    )

    let run = try await runner.run()
    let hybrid = try #require(run.result(for: .hybrid))
    let vector = try #require(run.result(for: .vectorOnly))
    let keyword = try #require(run.result(for: .keywordOnly))
    let markdown = MarkdownExporter.retrievalTable(for: run)

    #expect(run.questionCount == 24)
    #expect(hybrid.recallAt8 >= 0.8)
    #expect(hybrid.recallAt8 >= vector.recallAt8)
    #expect(hybrid.recallAt8 >= keyword.recallAt8)
    #expect(hybrid.mrr >= vector.mrr)
    #expect(hybrid.mrr >= keyword.mrr)
    #expect(markdown.contains("| Strategy | Questions | Recall@8 | MRR |"))
    #expect(markdown.contains("| Hybrid | 24 |"))
}

@MainActor
@Test func benchViewModelRunsRetrievalEvalFromInjectedRunner() async throws {
    let engine = FakeBenchEngine(outcomes: [.finished(metrics(ttft: 10, tokensPerSecond: 1, outputTokens: 4))])
    let benchRunner = BenchRunner(
        engine: engine,
        model: testModel,
        promptSuite: BenchPromptSuite(prompts: [BenchPrompt(id: "p", text: "Prompt")]),
        rounds: 1,
        memorySampler: MemorySampler(readPhysFootprintBytes: { 1 }),
        thermalObserver: ThermalObserver()
    )
    let retrievalRunner = try RetrievalEvalRunner.bundledFixture(
        idProvider: { "retrieval-run" },
        dateProvider: { Date(timeIntervalSince1970: 0) }
    )
    let viewModel = BenchViewModel(
        runner: benchRunner,
        retrievalEvalRunner: retrievalRunner,
        engineName: "Fake",
        modelName: "Model"
    )

    let task = try #require(viewModel.runRetrievalEval())
    await task.value

    #expect(viewModel.latestRetrievalEval?.id == "retrieval-run")
    #expect(viewModel.latestRetrievalEval?.questionCount == 24)
    #expect(viewModel.retrievalEvalErrorMessage == nil)
    #expect(viewModel.retrievalEvalMarkdown.contains("| Hybrid | 24 |"))
}

private let testModel = ModelIdentity(
    id: "mlx-community/Qwen3-1.7B-4bit",
    family: "qwen3",
    quantization: "4bit",
    contextLength: 32_768,
    estimatedMemoryBytes: 1_100_000_000
)

private func metrics(
    ttft: Double,
    tokensPerSecond: Double,
    outputTokens: Int
) -> GenerationMetrics {
    GenerationMetrics(
        firstTokenLatencyMillis: ttft,
        tokensPerSecond: tokensPerSecond,
        outputTokenCount: outputTokens
    )
}

private func result(
    ttft: Double,
    tokensPerSecond: Double,
    outputTokens: Int
) -> BenchRoundResult {
    BenchRoundResult(
        promptID: "p",
        round: 1,
        metrics: metrics(ttft: ttft, tokensPerSecond: tokensPerSecond, outputTokens: outputTokens)
    )
}

private actor FakeBenchEngine: LLMEngine {
    enum Outcome: Sendable {
        case finished(GenerationMetrics)
        case cancelled
        case failed
    }

    nonisolated let descriptor = EngineDescriptor(
        id: "fake",
        displayName: "Fake",
        kind: .mlx
    )

    private let outcomes: [Outcome]
    private var nextOutcomeIndex = 0
    private var loadedModels: [ModelIdentity] = []
    private var requestConfigs: [GenerationConfig] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func load(_ model: ModelIdentity) async throws {
        loadedModels.append(model)
    }

    func unload() async {}

    func generate(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        requestConfigs.append(request.config)
        let outcome = outcomes[min(nextOutcomeIndex, outcomes.count - 1)]
        nextOutcomeIndex += 1

        return AsyncThrowingStream { continuation in
            switch outcome {
            case .finished(let metrics):
                continuation.yield(.token("ok"))
                continuation.yield(.finished(.stop, metrics))
                continuation.finish()
            case .cancelled:
                continuation.yield(.finished(.cancelled, GenerationMetrics(
                    firstTokenLatencyMillis: nil,
                    tokensPerSecond: nil,
                    outputTokenCount: 0
                )))
                continuation.finish()
            case .failed:
                continuation.yield(.finished(.error, GenerationMetrics(
                    firstTokenLatencyMillis: nil,
                    tokensPerSecond: nil,
                    outputTokenCount: 0
                )))
                continuation.finish()
            }
        }
    }

    func countTokens(in text: String) async throws -> Int {
        text.count
    }

    func loadedModelIDs() -> [String] {
        loadedModels.map(\.id)
    }

    func capturedConfigs() -> [GenerationConfig] {
        requestConfigs
    }
}

private actor ProgressRecorder {
    private var recordedEvents: [BenchProgress] = []

    var events: [BenchProgress] {
        recordedEvents
    }

    func record(_ progress: BenchProgress) {
        recordedEvents.append(progress)
    }
}
