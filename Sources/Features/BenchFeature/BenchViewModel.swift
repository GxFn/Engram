import EngineKit
import Foundation
import MetricsKit
import Observation

@MainActor
@Observable
public final class BenchViewModel {
    public private(set) var history: [BenchRun] = []
    public private(set) var latestRun: BenchRun?
    public private(set) var progress: BenchProgress?
    public private(set) var isRunning = false
    public var errorMessage: String?

    public let engineName: String
    public let modelName: String

    @ObservationIgnored private let runner: BenchRunner
    @ObservationIgnored private var runTask: Task<Void, Never>?

    public init(
        engine: any LLMEngine,
        model: ModelIdentity,
        generationConfig: GenerationConfig = GenerationConfig(temperature: 0.2, topP: 0.9, maxTokens: 128)
    ) {
        self.runner = BenchRunner(engine: engine, model: model, config: generationConfig)
        self.engineName = engine.descriptor.displayName
        self.modelName = Self.displayName(for: model)
    }

    init(runner: BenchRunner, engineName: String, modelName: String) {
        self.runner = runner
        self.engineName = engineName
        self.modelName = modelName
    }

    public var exportMarkdown: String {
        MarkdownExporter.table(for: history)
    }

    public func run() {
        guard !isRunning else {
            return
        }

        isRunning = true
        progress = nil
        errorMessage = nil

        runTask = Task { [weak self] in
            guard let self else { return }

            do {
                let run = try await runner.run { [weak self] progress in
                    await self?.updateProgress(progress)
                }

                latestRun = run
                history.insert(run, at: 0)
            } catch is CancellationError {
                errorMessage = "Stopped."
            } catch {
                errorMessage = Self.userFacingMessage(for: error)
            }

            isRunning = false
            runTask = nil
        }
    }

    public func stop() {
        runTask?.cancel()
    }

    private func updateProgress(_ progress: BenchProgress) {
        self.progress = progress
    }

    private static func displayName(for model: ModelIdentity) -> String {
        model.id.split(separator: "/").last.map(String.init) ?? model.id
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let engineError = error as? EngineError {
            switch engineError {
            case .notImplemented(let message) where message.contains("simulator unsupported"):
                return "Simulator cannot run MLX. Use a device or macOS."
            case .notImplemented:
                return "Model setup is not ready yet."
            case .modelNotLoaded:
                return "Model is not loaded."
            case .outOfMemory:
                return "Not enough memory to run this model."
            case .cancelled:
                return "Stopped."
            }
        }

        if let runnerError = error as? BenchRunnerError {
            switch runnerError {
            case .emptyPromptSuite:
                return "Prompt suite is empty."
            case .missingGenerationMetrics:
                return "Generation metrics were missing."
            case .generationFinishedWithError:
                return "Generation failed."
            }
        }

        return "Benchmark failed."
    }
}
