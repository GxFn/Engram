import EngineKit
import Foundation
import Observation
import RAGCore

/// Answer scope: 全部(all) / 剪藏(text/url clips) / 拆解(video breakdowns).
public enum AskScope: String, Sendable, CaseIterable, Identifiable {
    case all
    case clips
    case studio

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "全部"
        case .clips: "剪藏"
        case .studio: "拆解"
        }
    }
}

public struct AskRetrievalConfiguration: Sendable, Hashable {
    public var resultLimit: Int
    public var minimumScore: Double
    public var promptTokenBudget: Int?

    public init(
        resultLimit: Int = 8,
        minimumScore: Double = 0.015,
        promptTokenBudget: Int? = nil
    ) {
        self.resultLimit = resultLimit
        self.minimumScore = minimumScore
        self.promptTokenBudget = promptTokenBudget
    }

    public static let `default` = AskRetrievalConfiguration()
}

@MainActor
@Observable
public final class AskViewModel {
    public nonisolated static let noSupportingClipsMessage = "你的拆解库里没有相关内容"

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
        public var citations: [CitationRef]
        public let createdAt: Date

        public init(
            id: UUID = UUID(),
            role: Role,
            text: String,
            metrics: GenerationMetrics? = nil,
            finishReason: FinishReason? = nil,
            errorMessage: String? = nil,
            citations: [CitationRef] = [],
            createdAt: Date = Date()
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.metrics = metrics
            self.finishReason = finishReason
            self.errorMessage = errorMessage
            self.citations = citations
            self.createdAt = createdAt
        }
    }

    public private(set) var messages: [DisplayMessage]
    public private(set) var isGenerating: Bool
    /// Which library the question is answered from: 全部 / 剪藏 / 拆解.
    public var scope: AskScope

    public let engineName: String
    public let modelName: String
    public let generationConfig: GenerationConfig

    @ObservationIgnored private let engine: any LLMEngine
    @ObservationIgnored private let model: ModelIdentity
    @ObservationIgnored private let retriever: (any Retriever)?
    @ObservationIgnored private let retrievalConfiguration: AskRetrievalConfiguration
    @ObservationIgnored private let videoClipIDsProvider: (@Sendable () async -> Set<String>)?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var loadedModelID: String?

    public init(
        engine: any LLMEngine,
        model: ModelIdentity,
        generationConfig: GenerationConfig = .default,
        retriever: (any Retriever)? = nil,
        retrievalConfiguration: AskRetrievalConfiguration = .default,
        scope: AskScope = .all,
        videoClipIDsProvider: (@Sendable () async -> Set<String>)? = nil,
        messages: [DisplayMessage] = []
    ) {
        self.engine = engine
        self.model = model
        self.retriever = retriever
        self.retrievalConfiguration = retrievalConfiguration
        self.scope = scope
        self.videoClipIDsProvider = videoClipIDsProvider
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

        let directRequestMessages = retriever == nil
            ? chatTranscript(appendingUserText: text)
            : []
        let assistantID = UUID()

        messages.append(DisplayMessage(role: .user, text: text))
        messages.append(DisplayMessage(id: assistantID, role: .assistant, text: ""))
        isGenerating = true

        let task = Task { [weak self] in
            guard let self else { return }
            if self.retriever == nil {
                await self.runGeneration(directRequestMessages, assistantID: assistantID)
            } else {
                await self.runGroundedGeneration(question: text, assistantID: assistantID)
            }
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

    private func runGroundedGeneration(question: String, assistantID: UUID) async {
        var receivedTerminalEvent = false

        defer {
            generationTask = nil
            isGenerating = false
        }

        do {
            try Task.checkCancellation()
            guard let retriever else {
                await runGeneration(chatTranscript(appendingUserText: question), assistantID: assistantID)
                return
            }

            let retrieved = try await retriever.retrieve(
                question: question,
                topK: retrievalConfiguration.resultLimit
            )
            let grounded = retrieved.filter { $0.score >= retrievalConfiguration.minimumScore }
            let scoped = await applyScope(grounded)

            guard !scoped.isEmpty else {
                markNoSupportingClips(assistantID)
                return
            }

            try Task.checkCancellation()
            try await ensureModelLoaded()
            try Task.checkCancellation()

            let prompt = try await buildGroundedPrompt(question: question, retrieved: scoped)
            attachCitations(prompt.citations, to: assistantID)

            let stream = await engine.generate(GenerationRequest(
                messages: [ChatMessage(role: .user, content: prompt.text)],
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

    /// Restricts retrieved chunks to the selected library. `.all` keeps everything; `.studio`
    /// keeps video-breakdown chunks; `.clips` keeps the rest. No-op without a resolver.
    private func applyScope(_ chunks: [RetrievedChunk]) async -> [RetrievedChunk] {
        guard scope != .all, let videoClipIDsProvider else {
            return chunks
        }
        let videoClipIDs = await videoClipIDsProvider()
        switch scope {
        case .studio:
            return chunks.filter { videoClipIDs.contains($0.chunk.clipID) }
        case .clips:
            return chunks.filter { !videoClipIDs.contains($0.chunk.clipID) }
        case .all:
            return chunks
        }
    }

    private struct GroundedPrompt: Sendable {
        let text: String
        let citations: [CitationRef]
    }

    private func buildGroundedPrompt(
        question: String,
        retrieved: [RetrievedChunk]
    ) async throws -> GroundedPrompt {
        let budget = promptTokenBudget()
        var selected = Array(retrieved.prefix(max(retrievalConfiguration.resultLimit, 1)))
        var prompt = Self.groundedPrompt(question: question, chunks: selected)

        while selected.count > 1 {
            let tokens = try await engine.countTokens(in: prompt)
            if tokens <= budget {
                return GroundedPrompt(text: prompt, citations: selected.map(\.citation))
            }
            selected.removeLast()
            prompt = Self.groundedPrompt(question: question, chunks: selected)
        }

        if let first = selected.first {
            var trimmedChunk = first
            var text = first.chunk.text
            while try await engine.countTokens(in: prompt) > budget, text.count > 160 {
                text = String(text.prefix(max(160, text.count / 2)))
                trimmedChunk = Self.replacingText(in: first, with: "\(text)...")
                prompt = Self.groundedPrompt(question: question, chunks: [trimmedChunk])
            }
            return GroundedPrompt(text: prompt, citations: [first.citation])
        }

        return GroundedPrompt(text: Self.noSupportingClipsMessage, citations: [])
    }

    private func promptTokenBudget() -> Int {
        if let promptTokenBudget = retrievalConfiguration.promptTokenBudget {
            return max(promptTokenBudget, 1)
        }

        let contextAfterGeneration = model.contextLength - generationConfig.maxTokens - 128
        return max(256, min(contextAfterGeneration, 4_096))
    }

    private nonisolated static func replacingText(
        in result: RetrievedChunk,
        with text: String
    ) -> RetrievedChunk {
        let chunk = Chunk(
            id: result.chunk.id,
            clipID: result.chunk.clipID,
            text: text,
            indexInClip: result.chunk.indexInClip,
            startOffset: result.chunk.startOffset,
            endOffset: result.chunk.endOffset,
            preview: result.chunk.preview
        )
        return RetrievedChunk(chunk: chunk, score: result.score, citation: result.citation)
    }

    private nonisolated static func groundedPrompt(
        question: String,
        chunks: [RetrievedChunk]
    ) -> String {
        let numberedChunks = chunks.enumerated().map { index, result in
            "[\(index + 1)] \(result.chunk.text)"
        }.joined(separator: "\n\n")

        return """
        以下是你的视频拆解库中的相关片段。仅基于这些内容回答，引用编号。不要使用拆解库外的信息；如果不足以回答，就回答“\(Self.noSupportingClipsMessage)”。

        拆解内容:
        \(numberedChunks)

        问题:
        \(question)
        """
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

    private func attachCitations(_ citations: [CitationRef], to id: UUID) {
        updateMessage(id) { message in
            message.citations = citations
        }
    }

    private func markNoSupportingClips(_ id: UUID) {
        updateMessage(id) { message in
            message.text = Self.noSupportingClipsMessage
            message.finishReason = .stop
        }
    }

    private func finishAssistantMessage(
        _ id: UUID,
        reason: FinishReason,
        metrics: GenerationMetrics
    ) {
        updateMessage(id) { message in
            message.text = Self.displayText(from: message.text)
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

            if Self.isNoSupportingClipsAnswer(message.text) {
                message.citations = []
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

    private nonisolated static func displayText(from rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.localizedCaseInsensitiveContains("<think") else {
            return trimmed
        }

        let closedThinkPattern = #"<think\b[^>]*>.*?</think>"#
        let trailingThinkPattern = #"<think\b[^>]*>.*$"#
        let strayThinkTagPattern = #"</?think\b[^>]*>"#
        return [closedThinkPattern, trailingThinkPattern, strayThinkTagPattern].reduce(trimmed) { text, pattern in
            replacingMatches(pattern, in: text, with: "")
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func isNoSupportingClipsAnswer(_ text: String) -> Bool {
        text.contains(noSupportingClipsMessage)
    }

    private nonisolated static func replacingMatches(
        _ pattern: String,
        in text: String,
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}
