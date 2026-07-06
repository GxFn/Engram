import EngineKit
import Foundation
import Observation

@MainActor
@Observable
public final class AskViewModel {
    public struct DisplayMessage: Identifiable, Sendable {
        public enum Role: Sendable {
            case user
            case assistant
        }

        public let id: UUID
        public let role: Role
        public var text: String
        public var metrics: GenerationMetrics?
        public var finishReason: FinishReason?
        public var errorMessage: String?
        public let createdAt: Date

        public init(
            id: UUID = UUID(),
            role: Role,
            text: String,
            metrics: GenerationMetrics? = nil,
            finishReason: FinishReason? = nil,
            errorMessage: String? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.metrics = metrics
            self.finishReason = finishReason
            self.errorMessage = errorMessage
            self.createdAt = createdAt
        }
    }

    public private(set) var messages: [DisplayMessage]
    public private(set) var isGenerating: Bool

    public let engineName: String
    public let modelName: String
    public let generationConfig: GenerationConfig

    @ObservationIgnored private let engine: any LLMEngine
    @ObservationIgnored private let model: ModelIdentity
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var loadedModelID: String?

    public init(
        engine: any LLMEngine,
        model: ModelIdentity,
        generationConfig: GenerationConfig = .default,
        messages: [DisplayMessage] = []
    ) {
        self.engine = engine
        self.model = model
        self.generationConfig = generationConfig
        self.engineName = engine.descriptor.displayName
        self.modelName = Self.displayName(for: model)
        self.messages = messages
        self.isGenerating = false
    }

    @discardableResult
    public func send(_ rawText: String) -> Task<Void, Never>? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else {
            return nil
        }

        let requestMessages = chatTranscript(appendingUserText: text)
        let assistantID = UUID()

        messages.append(DisplayMessage(role: .user, text: text))
        messages.append(DisplayMessage(id: assistantID, role: .assistant, text: ""))
        isGenerating = true

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runGeneration(requestMessages, assistantID: assistantID)
        }
        generationTask = task
        return task
    }

    public func stop() {
        generationTask?.cancel()
    }

    private func runGeneration(_ requestMessages: [ChatMessage], assistantID: UUID) async {
        var receivedTerminalEvent = false

        defer {
            generationTask = nil
            isGenerating = false
        }

        do {
            try Task.checkCancellation()
            try await ensureModelLoaded()
            try Task.checkCancellation()

            let stream = await engine.generate(GenerationRequest(
                messages: requestMessages,
                config: generationConfig
            ))
            for try await event in stream {
                switch event {
                case .token(let text):
                    appendAssistantText(text, to: assistantID)

                case .finished(let reason, let metrics):
                    receivedTerminalEvent = true
                    finishAssistantMessage(assistantID, reason: reason, metrics: metrics)
                }
            }

            if !receivedTerminalEvent, Task.isCancelled {
                markAssistantCancelled(assistantID)
            }
        } catch is CancellationError {
            if !receivedTerminalEvent {
                markAssistantCancelled(assistantID)
            }
        } catch {
            if !receivedTerminalEvent {
                markAssistantError(assistantID, error: error)
            }
        }
    }

    private func ensureModelLoaded() async throws {
        guard loadedModelID != model.id else {
            return
        }

        try await engine.load(model)
        loadedModelID = model.id
    }

    private func chatTranscript(appendingUserText text: String) -> [ChatMessage] {
        let previousMessages = messages.compactMap { message -> ChatMessage? in
            guard message.errorMessage == nil else {
                return nil
            }

            let content = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return nil
            }

            switch message.role {
            case .user:
                return ChatMessage(role: .user, content: content)
            case .assistant:
                return ChatMessage(role: .assistant, content: content)
            }
        }

        return previousMessages + [ChatMessage(role: .user, content: text)]
    }

    private func appendAssistantText(_ text: String, to id: UUID) {
        updateMessage(id) { message in
            message.text += text
        }
    }

    private func finishAssistantMessage(
        _ id: UUID,
        reason: FinishReason,
        metrics: GenerationMetrics
    ) {
        updateMessage(id) { message in
            message.metrics = metrics
            message.finishReason = reason

            if reason == .cancelled, message.text.isEmpty {
                message.text = "Stopped."
            } else if reason == .error, message.text.isEmpty {
                message.text = "Generation failed."
                message.errorMessage = message.text
            } else if message.text.isEmpty {
                message.text = "No response."
            }
        }
    }

    private func markAssistantCancelled(_ id: UUID) {
        updateMessage(id) { message in
            message.finishReason = .cancelled
            if message.text.isEmpty {
                message.text = "Stopped."
            }
        }
    }

    private func markAssistantError(_ id: UUID, error: Error) {
        let messageText = Self.userFacingMessage(for: error)
        updateMessage(id) { message in
            message.text = messageText
            message.errorMessage = messageText
            message.finishReason = .error
        }
    }

    private func updateMessage(_ id: UUID, _ update: (inout DisplayMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }

        update(&messages[index])
    }

    static func displayName(for model: ModelIdentity) -> String {
        model.id.split(separator: "/").last.map(String.init) ?? model.id
    }

    static func userFacingMessage(for error: Error) -> String {
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

        return "Generation failed."
    }
}
