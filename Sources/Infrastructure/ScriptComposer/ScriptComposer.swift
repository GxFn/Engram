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
    /// Only a genuine sub-word ASR fragment (e.g. a 0.1s "我") shorter than this is folded into an
    /// adjacent neighbour. Kept at fragment scale so legitimate fast-paced short sentences
    /// (0.5–0.8s, the 爆款 case) stay their own 分镜 — the prompt does the sentence-level segmentation,
    /// this only cleans up broken bits, and ShotMerger additionally requires temporal adjacency.
    public var minShotSeconds: Double

    public init(
        maxKeyframeCount: Int = 16,
        maxFrameBytes: Int = 8_000_000,
        generationConfig: GenerationConfig = .init(temperature: 0.2, topP: 0.9, maxTokens: 1_500),
        retryMalformedJSON: Bool = true,
        minShotSeconds: Double = 0.35
    ) {
        // Ceiling matches VideoAnalyzer.frameBudgetCeiling so the composer never silently trims the
        // analyzer's duration-adaptive frame budget back down.
        self.maxKeyframeCount = max(0, min(maxKeyframeCount, 16))
        self.maxFrameBytes = max(1, maxFrameBytes)
        self.generationConfig = generationConfig
        self.retryMalformedJSON = retryMalformedJSON
        self.minShotSeconds = max(0, minShotSeconds)
    }

    /// Config for the malformed-JSON retry: deterministic (t=0) with a doubled token budget — the
    /// most common decode failure is a token-truncated object, and retrying at the same budget
    /// just truncates again.
    var retryGenerationConfig: GenerationConfig {
        var config = generationConfig
        config.temperature = 0
        config.maxTokens = max(config.maxTokens * 2, 3_000)
        return config
    }
}

public protocol ScriptTextGenerating: Sendable {
    func generateScriptText(prompt: String, config: GenerationConfig) async throws -> String
}

public actor LLMTextScriptGenerator: ScriptTextGenerating {
    private let engine: any LLMEngine
    private let model: ModelIdentity?
    private let systemPrompt: String
    private var loadedModelID: String?

    public init(
        engine: any LLMEngine,
        model: ModelIdentity? = nil,
        systemPrompt: String = "你是 Engram 的端侧中文视频脚本编辑，只输出符合要求的 JSON。"
    ) {
        self.engine = engine
        self.model = model
        self.systemPrompt = systemPrompt
    }

    public func generateScriptText(prompt: String, config: GenerationConfig) async throws -> String {
        try await ensureModelLoadedIfNeeded()
        do {
            return try await collectGeneratedScriptText(prompt: prompt, config: config)
        } catch EngineError.modelNotLoaded where model != nil {
            loadedModelID = nil
            try await ensureModelLoadedIfNeeded()
            return try await collectGeneratedScriptText(prompt: prompt, config: config)
        }
    }

    private func ensureModelLoadedIfNeeded() async throws {
        guard let model, loadedModelID != model.id else {
            return
        }

        try await engine.load(model)
        loadedModelID = model.id
    }

    private func collectGeneratedScriptText(prompt: String, config: GenerationConfig) async throws -> String {
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
            case .finished(let reason, _):
                switch reason {
                case .stop:
                    return output
                case .length:
                    // Truncated at max tokens: return what we have (the JSON decoder's retry path
                    // handles an incomplete object), but make the cause visible in logs.
                    Log.scriptComposer.warning("Script generation hit the max-token limit; output may be truncated")
                    return output
                case .cancelled:
                    throw CancellationError()
                case .error:
                    // The engine reports the real error by throwing right after this event — keep
                    // consuming so it propagates instead of returning partial output as success.
                    continue
                }
            }
        }

        return output
    }
}

public actor Qwen3VLScriptComposer: VisionScriptComposing {
    private let generator: any VisionScriptGenerating
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
        generator: any VisionScriptGenerating,
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
        keyframes: [SampledFrame],
        onScreenText: [FrameText]
    ) async throws -> Script {
        let script = try await composeVision(
            sourceID: sourceID,
            transcript: transcript,
            keyframes: keyframes,
            onScreenText: onScreenText
        )
        // Every return path funnels through the deterministic grounding pass (see finalize): clamp
        // the timeline, ground 台词 in the transcript, attach OCR captions without orphans, fold
        // fragments. upperBound is a proxy for the video duration (source not available here).
        let upperBound = max(
            transcript.map(\.endSeconds).filter(\.isFinite).max() ?? 0,
            keyframes.map(\.timestampSeconds).filter(\.isFinite).max() ?? 0,
            onScreenText.map(\.timestampSeconds).filter(\.isFinite).max() ?? 0
        )
        return Self.finalize(
            script,
            transcript: transcript,
            onScreenText: onScreenText,
            upperBound: upperBound,
            minShotSeconds: configuration.minShotSeconds
        )
    }

    private func composeVision(
        sourceID: String,
        transcript: [TranscriptSegment],
        keyframes: [SampledFrame],
        onScreenText: [FrameText]
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
            keyframes: preparedFrames,
            onScreenText: onScreenText
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
                        config: configuration.retryGenerationConfig
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
            let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            Log.scriptComposer.error(
                "Qwen3-VL script generation failed: \(String(describing: error), privacy: .public)"
            )
            return try await transcriptFallback(
                sourceID: sourceID,
                transcript: transcript,
                reason: "画面理解失败：\(detail)"
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
            let script = try await textFallback.compose(sourceID: sourceID, transcript: transcript)
            return Self.annotate(script, reason: reason)
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

    /// Prepends the degradation reason to a fallback script's summary so the UI shows *why* 画面理解
    /// didn't run (e.g. HTTP 401 from the cloud VLM, or no sampled keyframes) instead of failing
    /// silently into a transcript dump.
    private nonisolated static func annotate(_ script: Script, reason: String) -> Script {
        guard !script.summary.contains(reason) else {
            return script
        }
        let summary = script.summary.isEmpty ? reason : "\(reason)\n\(script.summary)"
        return Script(
            id: script.id,
            videoSourceID: script.videoSourceID,
            title: script.title,
            summary: summary,
            shots: script.shots,
            createdAt: script.createdAt,
            hookStructure: script.hookStructure,
            visualElements: script.visualElements,
            characters: script.characters
        )
    }

    /// Deterministic grounding pass every compose result funnels through, in order:
    /// (1) clamp shot timestamps into [0, upperBound] so hallucinated out-of-range times can't hijack
    ///     caption/narration ownership; (2) ground each shot's 台词 in the authoritative corrected
    ///     transcript by time window — the VLM must never be trusted to reproduce 台词 verbatim;
    ///     (3) attach OCR captions with half-open windows so none are orphaned in timeline gaps;
    ///     (4) fold sub-fragment shots. Order matters: clamp before windowing, merge last.
    nonisolated static func finalize(
        _ script: Script,
        transcript: [TranscriptSegment],
        onScreenText: [FrameText],
        upperBound: Double,
        minShotSeconds: Double
    ) -> Script {
        let clamped = clampTimeline(script, upperBound: upperBound)
        let grounded = attachNarration(to: clamped, transcript: transcript)
        let withText = attachOnScreenText(to: grounded, onScreenText: onScreenText)
        let merged = ShotMerger.merge(withText.shots, minSeconds: minShotSeconds)
        return replacingShots(withText, shots: merged)
    }

    /// Grounds each shot's narration in the corrected transcript (verbatim, by half-open time window),
    /// so 台词 is exactly what was said — never the VLM's paraphrase, additions, or dropped lines.
    /// Runs only when a transcript exists; a shot whose window has no speech gets an empty narration
    /// (a silent / visual-only 分镜 has no 台词 — we never fabricate one).
    nonisolated static func attachNarration(to script: Script, transcript: [TranscriptSegment]) -> Script {
        guard !transcript.isEmpty, !script.shots.isEmpty else { return script }
        let sorted = script.shots.sorted { $0.startSeconds < $1.startSeconds }
        let bounds = windows(sorted)
        let shots = sorted.enumerated().map { position, shot -> StoryboardShot in
            let (lower, upper) = bounds[position]
            let spoken = transcript
                .filter { $0.startSeconds >= lower && $0.startSeconds < upper }
                .sorted { $0.startSeconds < $1.startSeconds }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let narration = spoken.isEmpty ? nil : spoken
            guard narration != shot.narration else { return shot }
            return StoryboardShot(
                index: shot.index, startSeconds: shot.startSeconds, endSeconds: shot.endSeconds,
                narration: narration, visualDescription: shot.visualDescription,
                pacingNote: shot.pacingNote, onScreenText: shot.onScreenText
            )
        }
        return replacingShots(script, shots: shots)
    }

    nonisolated static func attachOnScreenText(to script: Script, onScreenText: [FrameText]) -> Script {
        guard !onScreenText.isEmpty, !script.shots.isEmpty else { return script }
        let sorted = script.shots.sorted { $0.startSeconds < $1.startSeconds }
        let bounds = windows(sorted)
        let shots = sorted.enumerated().map { position, shot -> StoryboardShot in
            let (lower, upper) = bounds[position]
            let lines = onScreenText
                .filter { $0.timestampSeconds >= lower && $0.timestampSeconds < upper }
                .flatMap(\.lines)
            guard !lines.isEmpty else { return shot }

            var merged = shot.onScreenText
            for line in lines where !merged.contains(line) { merged.append(line) }
            guard merged != shot.onScreenText else { return shot }

            return StoryboardShot(
                index: shot.index, startSeconds: shot.startSeconds, endSeconds: shot.endSeconds,
                narration: shot.narration, visualDescription: shot.visualDescription,
                pacingNote: shot.pacingNote, onScreenText: merged
            )
        }
        return replacingShots(script, shots: shots)
    }

    /// Clamps shot timestamps into [0, upperBound]. A VLM sometimes emits end=9999 or start beyond
    /// the video; unclamped, such times would hijack the half-open ownership windows below.
    private nonisolated static func clampTimeline(_ script: Script, upperBound: Double) -> Script {
        guard upperBound.isFinite, upperBound > 0 else { return script }
        let shots = script.shots.map { shot -> StoryboardShot in
            let end = min(max(shot.endSeconds, 0), upperBound)
            let start = min(max(shot.startSeconds, 0), end)
            guard start != shot.startSeconds || end != shot.endSeconds else { return shot }
            return StoryboardShot(
                index: shot.index, startSeconds: start, endSeconds: end,
                narration: shot.narration, visualDescription: shot.visualDescription,
                pacingNote: shot.pacingNote, onScreenText: shot.onScreenText
            )
        }
        return replacingShots(script, shots: shots)
    }

    /// Half-open ownership windows partitioning the whole timeline across sorted shots: the first
    /// shot absorbs everything before the second's start (片头 titles/speech), the last extends to
    /// +∞ (trailing captions/speech). Guarantees no frame or transcript segment is orphaned.
    private nonisolated static func windows(_ sorted: [StoryboardShot]) -> [(Double, Double)] {
        sorted.indices.map { i in
            let lower = i == 0 ? -Double.greatestFiniteMagnitude : sorted[i].startSeconds
            let upper = i == sorted.count - 1 ? Double.greatestFiniteMagnitude : sorted[i + 1].startSeconds
            return (lower, upper)
        }
    }

    private nonisolated static func replacingShots(_ script: Script, shots: [StoryboardShot]) -> Script {
        Script(
            id: script.id,
            videoSourceID: script.videoSourceID,
            title: script.title,
            summary: script.summary,
            shots: shots,
            createdAt: script.createdAt,
            hookStructure: script.hookStructure,
            visualElements: script.visualElements,
            characters: script.characters
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
        model: ModelIdentity? = nil,
        configuration: ScriptComposerConfiguration = .init(maxKeyframeCount: 0),
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        idProvider: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.init(
            generator: LLMTextScriptGenerator(engine: engine, model: model),
            configuration: configuration,
            dateProvider: dateProvider,
            idProvider: idProvider
        )
    }

    public func compose(sourceID: String, transcript: [TranscriptSegment]) async throws -> Script {
        let prompt = ScriptPromptBuilder.textPrompt(transcript: transcript)
        var failureDetail = "文本模型暂不可用"

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
            failureDetail = "文本模型输出不是合法 JSON"

            if configuration.retryMalformedJSON {
                do {
                    let retryOutput = try await generator.generateScriptText(
                        prompt: ScriptPromptBuilder.retryPrompt(
                            originalPrompt: prompt,
                            malformedOutput: error.output
                        ),
                        config: configuration.retryGenerationConfig
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
            failureDetail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }

        return DeterministicScriptFactory.make(
            sourceID: sourceID,
            transcript: transcript,
            title: "语音转写草稿",
            summary: "剧本化未生效（\(failureDetail)），已根据语音转写生成单分镜草稿。",
            visualDescription: "",
            pacingNote: "仅基于语音转写，暂未使用画面理解。",
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
            id: idProvider(),
            allowsVisualFields: false // transcript-only: no frames to ground visual fields on
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
    static func visionPrompt(transcript: [TranscriptSegment], keyframes: [SampledFrame], onScreenText: [FrameText]) -> String {
        """
        你是 Engram 的中文短视频剧本师。根据已附加的关键帧图片、下面的转写和画面文字，生成可直接用于 AI 生图/生视频的爆款拆解分镜。
        只输出一个合法 JSON 对象，不要 Markdown，不要解释。字段严格如下：
        {
          "title": "中文标题",
          "summary": "一句中文摘要",
          "characters": ["每个元素是描述一个人物的一句中文（依次含称呼、性别年龄、发型发色、气质、服装），例：男生A是留黑色短发、穿浅色短袖的阳光男青年；共 2-5 个元素，判断不了就返回空数组"],
          "visualElements": ["场景/道具/风格/色调标签，3-8 个"],
          "hookStructure": {
            "openingHook": "前 3 秒钩子",
            "hookType": "钩子类型，从这九类里选最贴切的一个：悬念/共鸣/反差/痛点/利益前置/好奇/身份认同/情绪冲击/其他",
            "retentionDevices": ["留人手法"],
            "payoff": "爆点/反转/信息增量，可为空",
            "callToAction": "CTA，可为空",
            "whyItWorks": "为什么可能爆、为什么成立"
          },
          "shots": [
            {
              "start": 0.0,
              "end": 1.0,
              "narration": "台词或旁白，可为空",
              "visualDescription": "直接具体、可直接喂 AI 生图的一段画面：景别(特写/近景/中景/全景) + 出场人物(引用上面的称呼)及其表情/动作/位置 + 场景与背景 + 关键道具 + 光线/色调/风格",
              "pacingNote": "节奏/运镜建议，可为空"
            }
          ]
        }
        要求：
        - shots 按时间递增；每个完整句子、明显的语义节拍或说话人切换各自成为一个分镜，覆盖整条视频、不要漏掉任何一句台词；不要把多句台词并进同一个分镜，也不要把半句话拆成多个分镜；分镜边界落在一句话说完或画面明显切换处；
        - 每个 visualDescription 必须写实可拍、能直接生成画面，不要只复述台词，禁止“表情认真”“反应各异”这类笼统词；
        - narration 只需大致对齐时间；系统会用权威语音转写逐字覆盖 narration，你不要改写/翻译/增删台词；请把精力放在画面理解上；
        - “画面文字”是 OCR 识别的参考，可能夹带水印、@账号、点赞关注等 UI 文字，请结合关键帧图像判断哪些才是内容字幕，不要把 UI/水印当台词或据此扩写；
        - characters 里每个人物在各 shot 中保持同一称呼与外貌，方便下游生成一致的 AI 形象；
        - 不确定的真实姓名不要编造，可用“男生A”“女生B”等中性称呼。
        请分析这条为什么可能爆：前 3 秒钩子、留人手法、爆点/反转、CTA、为什么成立，并给出人物形象与关键视觉元素。

        转写：
        \(transcriptLines(transcript))

        画面文字（OCR 识别的烧录字幕/关键文字，按时间）：
        \(onScreenTextLines(onScreenText))

        关键帧（图片已按以下顺序附加）：
        \(keyframeLines(keyframes))
        """
    }

    static func textPrompt(transcript: [TranscriptSegment]) -> String {
        """
        你是 Engram 的端侧中文短视频脚本编辑。VLM 当前不可用，请只根据转写生成 transcript-only 爆款拆解分镜剧本。

        只输出一个合法 JSON 对象，不要 Markdown，不要解释。JSON 结构必须是：
        {
          "title": "中文标题",
          "summary": "一句中文摘要",
          "characters": [],
          "visualElements": [],
          "hookStructure": {
            "openingHook": "基于转写判断的前 3 秒钩子",
            "hookType": "钩子类型，从这九类里选最贴切的一个：悬念/共鸣/反差/痛点/利益前置/好奇/身份认同/情绪冲击/其他",
            "retentionDevices": ["基于转写判断的留人手法"],
            "payoff": "爆点/反转/信息增量，可为空",
            "callToAction": "CTA，可为空",
            "whyItWorks": "基于转写判断为什么可能爆、为什么成立"
          },
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

        要求 visualDescription 留空，因为没有画面输入。visualElements 可以为空数组，hookStructure 必须基于转写文本谨慎生成，不要编造画面细节。
        请分析这条为什么可能爆：前 3 秒钩子、留人手法、爆点/反转、CTA、为什么成立。shots 必须按时间递增。

        转写：
        \(transcriptLines(transcript))
        """
    }

    static func retryPrompt(originalPrompt: String, malformedOutput: String) -> String {
        """
        \(originalPrompt)

        上一次输出不是合法 JSON。现在只返回一个可被 JSONDecoder 解析的 JSON 对象，不要 Markdown，不要解释，不要前后缀文本。
        非法输出摘录：
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

    static func onScreenTextLines(_ texts: [FrameText]) -> String {
        let lines = texts
            .sorted { $0.timestampSeconds < $1.timestampSeconds }
            .map { "[\(format($0.timestampSeconds))s] \($0.lines.joined(separator: " / "))" }

        return lines.isEmpty ? "（无画面文字）" : lines.joined(separator: "\n")
    }
}

private enum JSONScriptDecoder {
    /// `allowsVisualFields` is false on the transcript-only path: without any frame input the model
    /// cannot ground characters / visualElements / visualDescription, so we strip them rather than
    /// let a hallucination through.
    static func decode(
        _ output: String,
        sourceID: String,
        transcript: [TranscriptSegment],
        createdAt: Date,
        id: String,
        allowsVisualFields: Bool = true
    ) throws -> Script {
        // Try every balanced JSON block in order: models sometimes emit a prose example object
        // before/after the real one, and only the block that yields substantive shots counts.
        let blocks = JSONEnvelope.candidates(output, open: "{", close: "}")
        let candidates = blocks.isEmpty
            ? [JSONEnvelope.slice(output, open: "{", close: "}")].compactMap { $0 }
            : blocks
        guard !candidates.isEmpty else {
            throw ScriptJSONDecodingError.noJSONObject(output)
        }

        var firstDecodeError: Error?
        var decodedButNoShots = false

        for data in candidates {
            let payload: ScriptPayload
            do {
                payload = try JSONDecoder().decode(ScriptPayload.self, from: data)
            } catch {
                if firstDecodeError == nil { firstDecodeError = error }
                continue
            }

            let decoded = payload.shots.enumerated().compactMap { index, shot in
                shot.storyboardShot(index: index)
            }

            // Reject pure empty-shell shots (only timestamps, no 台词 and no 画面): a model that
            // returns those must not pass as a real script — retry / transcript fallback instead.
            let substantive = decoded.filter { shot in
                !(shot.narration?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || !shot.visualDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !substantive.isEmpty else {
                decodedButNoShots = true
                continue
            }

            let shots = allowsVisualFields ? substantive : substantive.map { shot in
                StoryboardShot(
                    index: shot.index, startSeconds: shot.startSeconds, endSeconds: shot.endSeconds,
                    narration: shot.narration, visualDescription: "",
                    pacingNote: shot.pacingNote, onScreenText: shot.onScreenText
                )
            }

            return Script(
                id: id,
                videoSourceID: sourceID,
                title: payload.title.trimmedOrDefault(DeterministicScriptFactory.defaultTitle(for: transcript)),
                summary: payload.summary.trimmedOrDefault(DeterministicScriptFactory.defaultSummary(for: transcript)),
                shots: shots,
                createdAt: createdAt,
                hookStructure: payload.hookStructure,
                visualElements: allowsVisualFields ? payload.visualElements : [],
                characters: allowsVisualFields ? payload.characters : []
            )
        }

        if decodedButNoShots {
            throw ScriptJSONDecodingError.noShots(output)
        }
        throw ScriptJSONDecodingError.decoderFailed(
            output,
            firstDecodeError ?? ScriptJSONDecodingError.noJSONObject(output)
        )
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
    let visualElements: [String]
    let characters: [String]
    let hookStructure: HookAnalysis?
    let shots: [ShotPayload]

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case visualElements
        case characters
        case hookStructure
        case shots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        visualElements = Self.flexibleStringList(container, forKey: .visualElements)
        characters = Self.flexibleStringList(container, forKey: .characters)
        // Lenient: a malformed or partial hookStructure degrades to nil/partial instead of
        // failing the whole script decode and dropping otherwise-good shots.
        let hookPayload = (try? container.decodeIfPresent(HookPayload.self, forKey: .hookStructure)) ?? nil
        hookStructure = hookPayload?.hookAnalysis()
        shots = try container.decodeIfPresent([ShotPayload].self, forKey: .shots) ?? []
    }

    /// Decodes a list whose items may be plain strings OR small objects (the model occasionally
    /// returns `{"称呼":"男生A", …}` for a character); objects are flattened to one joined string.
    /// Never throws, so a formatting drift can't fail the whole script decode and drop good shots.
    private static func flexibleStringList(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String] {
        if let items = try? container.decodeIfPresent([FlexibleTextItem].self, forKey: key) {
            return items.map(\.text).filter { !$0.isEmpty }
        }
        // The model occasionally returns a single string instead of an array — recover it rather
        // than silently dropping the whole field (e.g. all characters). Split only on hard list
        // separators (newline/；); 、and ，legitimately appear INSIDE one description.
        if let single = try? container.decodeIfPresent(FlexibleTextItem.self, forKey: key),
           !single.text.isEmpty {
            return single.text
                .split(whereSeparator: { $0 == "\n" || $0 == "；" || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}

private struct FlexibleTextItem: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let string = try? single.decode(String.self) {
            text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let object = try? single.decode([String: FlexibleScalar].self) {
            text = object.values
                .map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: "，")
        } else {
            text = ""
        }
    }
}

private enum FlexibleScalar: Decodable {
    case value(String)

    var text: String {
        switch self {
        case let .value(string):
            return string
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .value(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let number = try? container.decode(Double.self) {
            self = .value(number == number.rounded() ? String(Int(number)) : String(number))
        } else if let bool = try? container.decode(Bool.self) {
            self = .value(bool ? "true" : "false")
        } else {
            self = .value("")
        }
    }
}

private struct HookPayload: Decodable {
    let openingHook: String
    let retentionDevices: [String]
    let payoff: String?
    let callToAction: String?
    let whyItWorks: String
    let hookType: HookType

    enum CodingKeys: String, CodingKey {
        case openingHook
        case retentionDevices
        case payoff
        case callToAction
        case whyItWorks
        case hookType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openingHook = try container.decodeIfPresent(String.self, forKey: .openingHook) ?? ""
        retentionDevices = try container.decodeIfPresent([String].self, forKey: .retentionDevices) ?? []
        payoff = try container.decodeIfPresent(String.self, forKey: .payoff)
        callToAction = try container.decodeIfPresent(String.self, forKey: .callToAction)
        whyItWorks = try container.decodeIfPresent(String.self, forKey: .whyItWorks) ?? ""
        hookType = HookType.from(try container.decodeIfPresent(String.self, forKey: .hookType) ?? "")
    }

    func hookAnalysis() -> HookAnalysis? {
        let devices = retentionDevices
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hook = openingHook.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = whyItWorks.trimmingCharacters(in: .whitespacesAndNewlines)
        let pay = payoff?.trimmedNilIfEmpty
        let cta = callToAction?.trimmedNilIfEmpty

        // Drop an entirely empty hook so ScriptRendering/UI can treat it as "no analysis".
        guard !hook.isEmpty || !why.isEmpty || !devices.isEmpty || pay != nil || cta != nil else {
            return nil
        }

        return HookAnalysis(
            openingHook: hook,
            retentionDevices: devices,
            payoff: pay,
            callToAction: cta,
            whyItWorks: why,
            hookType: hookType
        )
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
