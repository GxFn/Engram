import EngineKit
import Foundation
import MetricsKit

public struct BenchProgress: Sendable, Hashable {
    public let completedIterations: Int
    public let totalIterations: Int
    public let round: Int
    public let promptID: String
    public let promptText: String

    public init(
        completedIterations: Int,
        totalIterations: Int,
        round: Int,
        promptID: String,
        promptText: String
    ) {
        self.completedIterations = completedIterations
        self.totalIterations = totalIterations
        self.round = round
        self.promptID = promptID
        self.promptText = promptText
    }
}

public struct BenchRoundResult: Sendable {
    public let promptID: String
    public let round: Int
    public let metrics: GenerationMetrics

    public init(promptID: String, round: Int, metrics: GenerationMetrics) {
        self.promptID = promptID
        self.round = round
        self.metrics = metrics
    }
}

public enum BenchRunnerError: Error, Sendable, Equatable {
    case emptyPromptSuite
    case missingGenerationMetrics(String)
    case generationFinishedWithError(String)
}

public struct BenchRunner: Sendable {
    public let engine: any LLMEngine
    public let model: ModelIdentity
    public let config: GenerationConfig
    public let promptSuite: BenchPromptSuite
    public let rounds: Int
    public let memorySampler: MemorySampler
    public let thermalObserver: ThermalObserver
    private let idProvider: @Sendable () -> String
    private let dateProvider: @Sendable () -> Date
    private let deviceModelProvider: @Sendable () -> String

    public init(
        engine: any LLMEngine,
        model: ModelIdentity,
        config: GenerationConfig = GenerationConfig(temperature: 0.2, topP: 0.9, maxTokens: 128),
        promptSuite: BenchPromptSuite = (try? BenchPromptSuite.bundled()) ?? .builtIn,
        rounds: Int = 3,
        memorySampler: MemorySampler = MemorySampler(),
        thermalObserver: ThermalObserver = ThermalObserver(),
        idProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        dateProvider: @escaping @Sendable () -> Date = Date.init,
        deviceModelProvider: @escaping @Sendable () -> String = { ProcessInfo.processInfo.hostName }
    ) {
        self.engine = engine
        self.model = model
        self.config = config
        self.promptSuite = promptSuite
        self.rounds = max(1, rounds)
        self.memorySampler = memorySampler
        self.thermalObserver = thermalObserver
        self.idProvider = idProvider
        self.dateProvider = dateProvider
        self.deviceModelProvider = deviceModelProvider
    }

    public func run(
        progress: (@Sendable (BenchProgress) async -> Void)? = nil
    ) async throws -> BenchRun {
        guard !promptSuite.prompts.isEmpty else {
            throw BenchRunnerError.emptyPromptSuite
        }

        let startedAt = dateProvider()
        let totalIterations = promptSuite.prompts.count * rounds
        var completedIterations = 0

        let measurement = try await memorySampler.measure {
            try Task.checkCancellation()
            try await engine.load(model)

            var roundResults: [BenchRoundResult] = []
            for round in 1...rounds {
                for prompt in promptSuite.prompts {
                    try Task.checkCancellation()
                    let result = try await run(prompt: prompt, round: round)
                    roundResults.append(result)

                    completedIterations += 1
                    await progress?(BenchProgress(
                        completedIterations: completedIterations,
                        totalIterations: totalIterations,
                        round: round,
                        promptID: prompt.id,
                        promptText: prompt.text
                    ))
                }
            }

            return roundResults
        }

        let environment = thermalObserver.snapshot().environment(
            deviceModel: deviceModelProvider()
        )
        let samples = BenchAggregator.samples(
            from: measurement.value,
            peakMemoryBytes: measurement.peak.physFootprintBytes
        )

        return BenchRun(
            id: idProvider(),
            startedAt: startedAt,
            engineID: engine.descriptor.id,
            modelID: model.id,
            environment: environment,
            samples: samples
        )
    }

    private func run(prompt: BenchPrompt, round: Int) async throws -> BenchRoundResult {
        let request = GenerationRequest(
            messages: [ChatMessage(role: .user, content: prompt.text)],
            config: config
        )
        let stream = await engine.generate(request)
        var metrics: GenerationMetrics?

        for try await event in stream {
            switch event {
            case .token:
                continue

            case .finished(let reason, let finishedMetrics):
                switch reason {
                case .cancelled:
                    throw CancellationError()
                case .error:
                    throw BenchRunnerError.generationFinishedWithError(prompt.id)
                case .stop, .length:
                    metrics = finishedMetrics
                }
            }
        }

        guard let metrics else {
            throw BenchRunnerError.missingGenerationMetrics(prompt.id)
        }

        return BenchRoundResult(promptID: prompt.id, round: round, metrics: metrics)
    }
}
