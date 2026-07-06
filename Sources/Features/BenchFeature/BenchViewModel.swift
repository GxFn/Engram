import EngineKit
import Foundation
import MetricsKit
import Observation

@MainActor
@Observable
public final class BenchViewModel {
    public private(set) var history: [BenchRun] = []
    public private(set) var latestRun: BenchRun?
    public private(set) var latestRetrievalEval: RetrievalEvalRun?
    public private(set) var progress: BenchProgress?
    public private(set) var retrievalEvalProgress: RetrievalEvalProgress?
    public private(set) var isRunning = false
    public private(set) var isRunningRetrievalEval = false
    public var errorMessage: String?
    public var retrievalEvalErrorMessage: String?

    public let engineName: String
    public let modelName: String

    @ObservationIgnored private let runner: BenchRunner
    @ObservationIgnored private let retrievalEvalRunner: RetrievalEvalRunner?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var retrievalEvalTask: Task<Void, Never>?

    public init(
        engine: any LLMEngine,
        model: ModelIdentity,
        generationConfig: GenerationConfig = GenerationConfig(temperature: 0.2, topP: 0.9, maxTokens: 128),
        retrievalEvalRunner: RetrievalEvalRunner? = nil
    ) {
        self.runner = BenchRunner(engine: engine, model: model, config: generationConfig)
        self.retrievalEvalRunner = retrievalEvalRunner ?? (try? RetrievalEvalRunner.bundledFixture())
        self.engineName = engine.descriptor.displayName
        self.modelName = Self.displayName(for: model)
    }

    init(
        runner: BenchRunner,
        retrievalEvalRunner: RetrievalEvalRunner? = nil,
        engineName: String,
        modelName: String
    ) {
        self.runner = runner
        self.retrievalEvalRunner = retrievalEvalRunner
        self.engineName = engineName
        self.modelName = modelName
    }

    public var exportMarkdown: String {
        MarkdownExporter.table(for: history)
    }

    public var retrievalEvalMarkdown: String {
        guard let latestRetrievalEval else {
            return MarkdownExporter.retrievalHeader
        }

        return MarkdownExporter.retrievalTable(for: latestRetrievalEval)
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

    @discardableResult
    public func runRetrievalEval() -> Task<Void, Never>? {
        guard !isRunningRetrievalEval else {
            return retrievalEvalTask
        }

        guard let retrievalEvalRunner else {
            retrievalEvalErrorMessage = Self.userFacingMessage(for: RetrievalEvalError.noRetrievalClient)
            return nil
        }

        isRunningRetrievalEval = true
        retrievalEvalProgress = nil
        retrievalEvalErrorMessage = nil

        retrievalEvalTask = Task { [weak self] in
            guard let self else { return }

            do {
                let run = try await retrievalEvalRunner.run { [weak self] progress in
                    await self?.updateRetrievalEvalProgress(progress)
                }
                latestRetrievalEval = run
            } catch is CancellationError {
                retrievalEvalErrorMessage = "Stopped."
            } catch {
                retrievalEvalErrorMessage = Self.userFacingMessage(for: error)
            }

            isRunningRetrievalEval = false
            retrievalEvalTask = nil
        }

        return retrievalEvalTask
    }

    public func stopRetrievalEval() {
        retrievalEvalTask?.cancel()
    }

    private func updateProgress(_ progress: BenchProgress) {
        self.progress = progress
    }

    private func updateRetrievalEvalProgress(_ progress: RetrievalEvalProgress) {
        self.retrievalEvalProgress = progress
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

        if let retrievalEvalError = error as? RetrievalEvalError {
            switch retrievalEvalError {
            case .missingSuiteResource:
                return "Retrieval eval suite is missing."
            case .invalidSuite:
                return "Retrieval eval suite is invalid."
            case .noRetrievalClient:
                return "Retrieval eval is unavailable."
            }
        }

        return "Benchmark failed."
    }
}
