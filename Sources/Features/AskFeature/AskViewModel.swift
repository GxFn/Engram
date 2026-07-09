import EngineKit
import Foundation
import Observation
import RAGCore

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
    public nonisolated static let noSupportingClipsMessage = "我在你保存的内容里没找到相关的内容"

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
    /// True while retrieving grounding before generation starts (drives the "检索中" hint).
    public private(set) var isRetrieving: Bool

    public let engineName: String
    public let modelName: String
    public let generationConfig: GenerationConfig

    @ObservationIgnored private let engine: any LLMEngine
    @ObservationIgnored private let model: ModelIdentity
    @ObservationIgnored private let retriever: (any Retriever)?
    @ObservationIgnored private let retrievalConfiguration: AskRetrievalConfiguration
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var loadedModelID: String?

    public init(
        engine: any LLMEngine,
        model: ModelIdentity,
        generationConfig: GenerationConfig = .default,
        retriever: (any Retriever)? = nil,
        retrievalConfiguration: AskRetrievalConfiguration = .default,
        messages: [DisplayMessage] = []
    ) {
        self.engine = engine
        self.model = model
        self.retriever = retriever
        self.retrievalConfiguration = retrievalConfiguration
        self.generationConfig = generationConfig
        self.engineName = engine.descriptor.displayName
        self.modelName = Self.displayName(for: model)
        self.messages = messages
        self.isGenerating = false
        self.isRetrieving = false
    }

    /// Example prompts shown on the empty Ask screen to make the surface feel guided/smart.
    public nonisolated static let suggestedPrompts: [String] = [
        "帮我总结最近保存的重点",
        "我存的开场钩子都怎么写的？",
        "有哪些讲同一个主题的内容？",
        "把最近的视频拆解列成选题清单",
    ]

    /// Friendly assistant persona shared by grounded + direct chat, so answers read as a helpful
    /// guide over the user's saved content rather than a verbatim quote of the source material.
    nonisolated static let systemPrompt = """
    你是 Engram 的智能助手，帮我理解和用好我保存的内容（剪藏的文字、链接，以及视频拆解等）。请友好、自然、有条理地回答：用你自己的话把要点讲清楚，可以归纳、解释或举例，需要时分点，不要照抄原文。基于我给你的资料作答，用到某条时在句尾标注它的编号 [n]；如果资料不足以回答，就坦诚说明，并给我下一步可以怎么问或该保存什么的建议，不要编造。
    """

    private nonisolated static func withSystemPrompt(_ messages: [ChatMessage]) -> [ChatMessage] {
        [ChatMessage(role: .system, content: systemPrompt)] + messages
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
            isRetrieving = false
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
            isRetrieving = false
        }

        do {
            try Task.checkCancellation()
            guard let retriever else {
                await runGeneration(chatTranscript(appendingUserText: question), assistantID: assistantID)
                return
            }

            isRetrieving = true
            let retrieved = try await retriever.retrieve(
                question: question,
                topK: retrievalConfiguration.resultLimit
            )
            isRetrieving = false
            let grounded = retrieved.filter { $0.score >= retrievalConfiguration.minimumScore }

            guard !grounded.isEmpty else {
                markNoSupportingClips(assistantID)
                return
            }

            try Task.checkCancellation()
            try await ensureModelLoaded()
            try Task.checkCancellation()

            let prompt = try await buildGroundedPrompt(question: question, retrieved: grounded)
            attachCitations(prompt.citations, to: assistantID)

            let stream = await engine.generate(GenerationRequest(
                messages: Self.withSystemPrompt([ChatMessage(role: .user, content: prompt.text)]),
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
        下面是从我保存的内容里找到的相关资料。请据此回答我的问题：可以归纳、解释、举例，用自然的话讲清楚，并在用到某条资料时于句尾标注它的编号 [n]。如果这些资料不足以回答，就直说没找到相关内容，并建议我可以怎么问或该保存些什么，不要编造。

        资料:
        \(numberedChunks)

        我的问题:
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

        return Self.withSystemPrompt(previousMessages + [ChatMessage(role: .user, content: text)])
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

        // Cloud engine errors (CloudVLMError) arrive as LocalizedError — surface the real reason
        // (HTTP status + server body) instead of a generic failure, so a bad model/key is visible.
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
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
