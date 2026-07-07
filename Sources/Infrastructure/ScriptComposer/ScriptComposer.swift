import EngineKit
import EngramLogging
import Foundation
import QwenVLRuntime
import ScriptCore
import VideoUnderstanding

public struct ScriptComposerConfiguration: Sendable, Hashable {
    public var maxKeyframeCount: Int
    public var maxFrameBytes: Int
    public var generationConfig: GenerationConfig
    public var retryMalformedJSON: Bool

    public init(
        maxKeyframeCount: Int = 6,
        maxFrameBytes: Int = 8_000_000,
        generationConfig: GenerationConfig = .init(temperature: 0.2, topP: 0.9, maxTokens: 1_500),
        retryMalformedJSON: Bool = true
    ) {
        self.maxKeyframeCount = max(0, min(maxKeyframeCount, 8))
        self.maxFrameBytes = max(1, maxFrameBytes)
        self.generationConfig = generationConfig
        self.retryMalformedJSON = retryMalformedJSON
    }
}

public protocol ScriptTextGenerating: Sendable {
    func generateScriptText(prompt: String, config: GenerationConfig) async throws -> String
}

public actor LLMTextScriptGenerator: ScriptTextGenerating {
    private let engine: any LLMEngine
    private let systemPrompt: String

    public init(
        engine: any LLMEngine,
        systemPrompt: String = "你是 Engram 的端侧中文视频脚本编辑，只输出符合要求的 JSON。"
    ) {
        self.engine = engine
        self.systemPrompt = systemPrompt
    }

    public func generateScriptText(prompt: String, config: GenerationConfig) async throws -> String {
        let stream = await engine.generate(GenerationRequest(
            messages: [
                ChatMessage(role: .system, content: systemPrompt),
                ChatMessage(role: .user, content: prompt),
            ],
            config: config
        ))

        var output = ""
        for try await event in stream {
            if Task.isCancelled {
                throw CancellationError()
            }

            switch event {
            case .token(let token):
                output += token
            case .finished:
                return output
            }
        }

        return output
    }
}

public actor Qwen3VLScriptComposer: VisionScriptComposing {
    private let generator: any QwenVLGenerating
    private let textFallback: (any TextScriptComposing)?
    private let configuration: ScriptComposerConfiguration
    private let dateProvider: @Sendable () -> Date
    private let idProvider: @Sendable () -> String

    public init(
        modelDirectoryRoot: URL? = nil,
        configuration: ScriptComposerConfiguration = .init(),
        textFallback: (any TextScriptComposing)? = nil
    ) {
        self.init(
            generator: QwenVLContainer(modelDirectoryRoot: modelDirectoryRoot),
            configuration: configuration,
            textFallback: textFallback
        )
    }

    public init(
        generator: any QwenVLGenerating,
        configuration: ScriptComposerConfiguration = .init(),
        textFallback: (any TextScriptComposing)? = nil,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        idProvider: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.generator = generator
        self.configuration = configuration
        self.textFallback = textFallback
        self.dateProvider = dateProvider
        self.idProvider = idProvider
    }

    public func compose(
        sourceID: String,
        transcript: [TranscriptSegment],
        keyframes: [SampledFrame]
    ) async throws -> Script {
        let preparedFrames: [SampledFrame]
        do {
            preparedFrames = try FramePreparer.prepare(
                keyframes,
                maxCount: configuration.maxKeyframeCount,
                maxBytes: configuration.maxFrameBytes
            )
        } catch {
            Log.scriptComposer.error(
                "Qwen3-VL script frame preparation failed: \(String(describing: error), privacy: .public)"
            )
            return try await transcriptFallback(
                sourceID: sourceID,
                transcript: transcript,
                reason: "关键帧不可用，已转写-only 兜底。"
            )
        }

        guard !preparedFrames.isEmpty else {
            Log.scriptComposer.warning("Qwen3-VL script composer received no keyframes; using transcript-only fallback")
            return try await transcriptFallback(
                sourceID: sourceID,
                transcript: transcript,
                reason: "无可用关键帧，已转写-only 兜底。"
            )
        }

        let prompt = ScriptPromptBuilder.visionPrompt(
            transcript: transcript,
            keyframes: preparedFrames
        )

        do {
            let output = try await generator.generate(
                prompt: prompt,
                frames: preparedFrames,
                config: configuration.generationConfig
            )
            return try decodeScript(output, sourceID: sourceID, transcript: transcript)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScriptJSONDecodingError {
            Log.scriptComposer.warning(
                "Qwen3-VL script JSON decode failed: \(String(describing: error), privacy: .public)"
            )

            if configuration.retryMalformedJSON {
                do {
                    let retryOutput = try await generator.generate(
                        prompt: ScriptPromptBuilder.retryPrompt(
                            originalPrompt: prompt,
                            malformedOutput: error.output
                        ),
                        frames: preparedFrames,
                        config: configuration.generationConfig
                    )
                    return try decodeScript(retryOutput, sourceID: sourceID, transcript: transcript)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.scriptComposer.warning(
                        "Qwen3-VL script JSON retry failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }

            return DeterministicScriptFactory.make(
                sourceID: sourceID,
                transcript: transcript,
                title: "转写兜底剧本",
                summary: "模型输出不是合法 JSON，已根据转写生成单分镜剧本。",
                visualDescription: "模型输出不可解析，已根据转写生成兜底分镜。",
                pacingNote: "坏 JSON 兜底",
                createdAt: dateProvider(),
                id: idProvider()
            )
        } catch {
            Log.scriptComposer.error(
                "Qwen3-VL script generation failed: \(String(describing: error), privacy: .public)"
            )
            return try await transcriptFallback(
                sourceID: sourceID,
                transcript: transcript,
                reason: "VLM 不可用，已转写-only 兜底。"
            )
        }
    }

    private func decodeScript(
        _ output: String,
        sourceID: String,
        transcript: [TranscriptSegment]
    ) throws -> Script {
        try JSONScriptDecoder.decode(
            output,
            sourceID: sourceID,
            transcript: transcript,
            createdAt: dateProvider(),
            id: idProvider()
        )
    }

    private func transcriptFallback(
        sourceID: String,
        transcript: [TranscriptSegment],
        reason: String
    ) async throws -> Script {
        if let textFallback {
            return try await textFallback.compose(sourceID: sourceID, transcript: transcript)
        }

        return DeterministicScriptFactory.make(
            sourceID: sourceID,
            transcript: transcript,
            title: "转写-only 剧本",
            summary: reason,
            visualDescription: "转写-only 兜底：未使用画面理解。",
            pacingNote: "转写-only 兜底",
            createdAt: dateProvider(),
            id: idProvider()
        )
    }
}

public actor TextScriptComposer: TextScriptComposing {
    private let generator: any ScriptTextGenerating
    private let configuration: ScriptComposerConfiguration
    private let dateProvider: @Sendable () -> Date
    private let idProvider: @Sendable () -> String

    public init(
        generator: any ScriptTextGenerating,
        configuration: ScriptComposerConfiguration = .init(maxKeyframeCount: 0),
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        idProvider: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.generator = generator
        self.configuration = configuration
        self.dateProvider = dateProvider
        self.idProvider = idProvider
    }

    public init(
        engine: any LLMEngine,
        configuration: ScriptComposerConfiguration = .init(maxKeyframeCount: 0),
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        idProvider: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.init(
            generator: LLMTextScriptGenerator(engine: engine),
            configuration: configuration,
            dateProvider: dateProvider,
            idProvider: idProvider
        )
    }

    public func compose(sourceID: String, transcript: [TranscriptSegment]) async throws -> Script {
        let prompt = ScriptPromptBuilder.textPrompt(transcript: transcript)

        do {
            let output = try await generator.generateScriptText(
                prompt: prompt,
                config: configuration.generationConfig
            )
            return try decodeScript(output, sourceID: sourceID, transcript: transcript)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScriptJSONDecodingError {
            Log.scriptComposer.warning(
                "Text script JSON decode failed: \(String(describing: error), privacy: .public)"
            )

            if configuration.retryMalformedJSON {
                do {
                    let retryOutput = try await generator.generateScriptText(
                        prompt: ScriptPromptBuilder.retryPrompt(
                            originalPrompt: prompt,
                            malformedOutput: error.output
                        ),
                        config: configuration.generationConfig
                    )
                    return try decodeScript(retryOutput, sourceID: sourceID, transcript: transcript)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.scriptComposer.warning(
                        "Text script JSON retry failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        } catch {
            Log.scriptComposer.error(
                "Text script generation failed: \(String(describing: error), privacy: .public)"
            )
        }

        return DeterministicScriptFactory.make(
            sourceID: sourceID,
            transcript: transcript,
            title: "转写-only 剧本",
            summary: "文本剧本化不可用，已根据转写生成单分镜剧本。",
            visualDescription: "",
            pacingNote: "转写-only 兜底",
            createdAt: dateProvider(),
            id: idProvider()
        )
    }

    private func decodeScript(
        _ output: String,
        sourceID: String,
        transcript: [TranscriptSegment]
    ) throws -> Script {
        try JSONScriptDecoder.decode(
            output,
            sourceID: sourceID,
            transcript: transcript,
            createdAt: dateProvider(),
            id: idProvider()
        )
    }
}

private enum FramePreparer {
    static func prepare(_ frames: [SampledFrame], maxCount: Int, maxBytes: Int) throws -> [SampledFrame] {
        guard maxCount > 0 else {
            return []
        }

        return try frames
            .sorted { lhs, rhs in lhs.timestampSeconds < rhs.timestampSeconds }
            .prefix(maxCount)
            .map { frame in
                guard frame.timestampSeconds.isFinite, frame.timestampSeconds >= 0 else {
                    throw VideoUnderstandingError.visionUnavailable(
                        "Qwen3-VL script frame has an invalid timestamp: \(frame.timestampSeconds)."
                    )
                }

                guard !frame.jpegData.isEmpty else {
                    throw VideoUnderstandingError.visionUnavailable(
                        "Qwen3-VL script frame at \(frame.timestampSeconds)s has empty JPEG data."
                    )
                }

                guard frame.jpegData.count <= maxBytes else {
                    throw VideoUnderstandingError.visionUnavailable(
                        "Qwen3-VL script frame at \(frame.timestampSeconds)s exceeds \(maxBytes) bytes."
                    )
                }

                guard frame.jpegData.starts(with: [0xFF, 0xD8]) else {
                    throw VideoUnderstandingError.visionUnavailable(
                        "Qwen3-VL script frame at \(frame.timestampSeconds)s is not JPEG data."
                    )
                }

                return frame
            }
    }
}

private enum ScriptPromptBuilder {
    static func visionPrompt(transcript: [TranscriptSegment], keyframes: [SampledFrame]) -> String {
        """
        你是 Engram 的端侧中文短视频剧本师。请结合随本消息附带的关键帧图片和转写台词，按时间顺序输出结构化分镜剧本。

        只输出一个合法 JSON 对象，不要 Markdown，不要解释。JSON 结构必须是：
        {
          "title": "中文标题",
          "summary": "一句中文摘要",
          "shots": [
            {
              "start": 0.0,
              "end": 3.2,
              "narration": "该分镜对应的台词或旁白，可为空",
              "visualDescription": "结合关键帧看到的画面、人物、动作、场景",
              "pacingNote": "节奏/剪辑建议，可为空"
            }
          ]
        }

        要求：
        - shots 必须按时间递增，覆盖主要内容，不要虚构看不到的画面。
        - visualDescription 要体现关键帧画面，不要只复述转写。
        - narration 使用转写原文或忠实概括；中文表达自然。
        - 如果转写为空，也要根据关键帧输出可索引的画面分镜。

        转写：
        \(transcriptLines(transcript))

        关键帧（图片按以下顺序附加到同一条消息）：
        \(keyframeLines(keyframes))
        """
    }

    static func textPrompt(transcript: [TranscriptSegment]) -> String {
        """
        你是 Engram 的端侧中文短视频脚本编辑。VLM 当前不可用，请只根据转写生成 transcript-only 结构化分镜剧本。

        只输出一个合法 JSON 对象，不要 Markdown，不要解释。JSON 结构必须是：
        {
          "title": "中文标题",
          "summary": "一句中文摘要",
          "shots": [
            {
              "start": 0.0,
              "end": 3.2,
              "narration": "转写台词或旁白",
              "visualDescription": "",
              "pacingNote": "节奏/剪辑建议，可为空"
            }
          ]
        }

        要求 visualDescription 留空，因为没有画面输入。shots 必须按时间递增。

        转写：
        \(transcriptLines(transcript))
        """
    }

    static func retryPrompt(originalPrompt: String, malformedOutput: String) -> String {
        """
        \(originalPrompt)

        上一次输出不是合法 JSON。请只返回修正后的 JSON 对象，不要 Markdown，不要解释。
        上一次输出摘录：
        \(malformedOutput.prefix(1_000))
        """
    }

    private static func transcriptLines(_ transcript: [TranscriptSegment]) -> String {
        let lines = transcript
            .sorted { lhs, rhs in lhs.startSeconds < rhs.startSeconds }
            .map { segment in
                "[\(format(segment.startSeconds))s-\(format(segment.endSeconds))s] \(segment.text)"
            }

        return lines.isEmpty ? "（无转写）" : lines.joined(separator: "\n")
    }

    private static func keyframeLines(_ keyframes: [SampledFrame]) -> String {
        let lines = keyframes.enumerated().map { index, frame in
            "frame_\(index + 1): timestamp=\(format(frame.timestampSeconds))s, jpegBytes=\(frame.jpegData.count)"
        }

        return lines.isEmpty ? "（无关键帧）" : lines.joined(separator: "\n")
    }
}

private enum JSONScriptDecoder {
    static func decode(
        _ output: String,
        sourceID: String,
        transcript: [TranscriptSegment],
        createdAt: Date,
        id: String
    ) throws -> Script {
        let data = try extractJSONObject(from: output)
        let payload: ScriptPayload
        do {
            payload = try JSONDecoder().decode(ScriptPayload.self, from: data)
        } catch {
            throw ScriptJSONDecodingError.decoderFailed(output, error)
        }
        let shots = payload.shots.enumerated().compactMap { index, shot in
            shot.storyboardShot(index: index)
        }

        guard !shots.isEmpty else {
            throw ScriptJSONDecodingError.noShots(output)
        }

        return Script(
            id: id,
            videoSourceID: sourceID,
            title: payload.title.trimmedOrDefault(DeterministicScriptFactory.defaultTitle(for: transcript)),
            summary: payload.summary.trimmedOrDefault(DeterministicScriptFactory.defaultSummary(for: transcript)),
            shots: shots,
            createdAt: createdAt
        )
    }

    private static func extractJSONObject(from output: String) throws -> Data {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let start = trimmed.firstIndex(of: "{"),
            let end = trimmed.lastIndex(of: "}"),
            start <= end
        else {
            throw ScriptJSONDecodingError.noJSONObject(output)
        }

        return Data(trimmed[start ... end].utf8)
    }
}

private enum ScriptJSONDecodingError: Error, CustomStringConvertible {
    case noJSONObject(String)
    case noShots(String)
    case decoderFailed(String, Error)

    var output: String {
        switch self {
        case .noJSONObject(let output), .noShots(let output), .decoderFailed(let output, _):
            output
        }
    }

    var description: String {
        switch self {
        case .noJSONObject:
            "no JSON object found"
        case .noShots:
            "no valid storyboard shots found"
        case .decoderFailed(_, let error):
            "JSON decoder failed: \(error)"
        }
    }
}

private struct ScriptPayload: Decodable {
    let title: String
    let summary: String
    let shots: [ShotPayload]

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case shots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        shots = try container.decodeIfPresent([ShotPayload].self, forKey: .shots) ?? []
    }
}

private struct ShotPayload: Decodable {
    let startSeconds: Double
    let endSeconds: Double
    let narration: String?
    let visualDescription: String
    let pacingNote: String?

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case startSeconds
        case endSeconds
        case narration
        case visualDescription
        case pacingNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startSeconds = try container.decodeFlexibleDouble(keys: [.startSeconds, .start]) ?? 0
        endSeconds = try container.decodeFlexibleDouble(keys: [.endSeconds, .end]) ?? (startSeconds + 1)
        narration = try container.decodeIfPresent(String.self, forKey: .narration)
        visualDescription = try container.decodeIfPresent(String.self, forKey: .visualDescription) ?? ""
        pacingNote = try container.decodeIfPresent(String.self, forKey: .pacingNote)
    }

    func storyboardShot(index: Int) -> StoryboardShot? {
        guard startSeconds.isFinite, endSeconds.isFinite else {
            return nil
        }

        let safeStart = max(0, startSeconds)
        let safeEnd = endSeconds > safeStart ? endSeconds : safeStart + 1

        return StoryboardShot(
            index: index,
            startSeconds: safeStart,
            endSeconds: safeEnd,
            narration: narration?.trimmedNilIfEmpty,
            visualDescription: visualDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            pacingNote: pacingNote?.trimmedNilIfEmpty
        )
    }
}

private enum DeterministicScriptFactory {
    static func make(
        sourceID: String,
        transcript: [TranscriptSegment],
        title: String,
        summary: String,
        visualDescription: String,
        pacingNote: String,
        createdAt: Date,
        id: String
    ) -> Script {
        let timing = timingRange(for: transcript)
        let narration = transcript
            .sorted { lhs, rhs in lhs.startSeconds < rhs.startSeconds }
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return Script(
            id: id,
            videoSourceID: sourceID,
            title: title,
            summary: summary,
            shots: [
                StoryboardShot(
                    index: 0,
                    startSeconds: timing.start,
                    endSeconds: timing.end,
                    narration: narration.isEmpty ? "暂无可用转写。" : narration,
                    visualDescription: visualDescription,
                    pacingNote: pacingNote
                )
            ],
            createdAt: createdAt
        )
    }

    static func defaultTitle(for transcript: [TranscriptSegment]) -> String {
        let firstText = transcript
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let firstText else {
            return "视频分镜剧本"
        }

        return String(firstText.prefix(24))
    }

    static func defaultSummary(for transcript: [TranscriptSegment]) -> String {
        if transcript.isEmpty {
            return "根据视频理解结果生成的结构化分镜剧本。"
        }

        return "根据 \(transcript.count) 段转写生成的结构化分镜剧本。"
    }

    private static func timingRange(for transcript: [TranscriptSegment]) -> (start: Double, end: Double) {
        let starts = transcript.map(\.startSeconds).filter(\.isFinite)
        let ends = transcript.map(\.endSeconds).filter(\.isFinite)
        let start = max(0, starts.min() ?? 0)
        let rawEnd = max(ends.max() ?? 1, start + 1)
        return (start, rawEnd)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDouble(keys: [Key]) throws -> Double? {
        for key in keys {
            if let value = try decodeIfPresent(Double.self, forKey: key) {
                return value
            }

            if let value = try decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }

            if let value = try decodeIfPresent(String.self, forKey: key), let number = Double(value) {
                return number
            }
        }

        return nil
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func trimmedOrDefault(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

private func format(_ seconds: Double) -> String {
    String(format: "%.1f", seconds.isFinite ? seconds : 0)
}
