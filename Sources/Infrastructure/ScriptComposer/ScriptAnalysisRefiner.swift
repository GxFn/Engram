import EngineKit
import EngramLogging
import Foundation
import ScriptCore
import VideoUnderstanding

/// Re-derives a breakdown's UNDERSTANDING fields (title / summary / 爆点结构) from its corrected
/// facts — 台词, 字幕, and the user's background note — without re-running the video pipeline.
/// This is the AI half of the human-in-the-loop correction: the user fixes facts or supplies the
/// 梗/题材 the model couldn't know, and a cheap text call re-analyzes on top of them. Shots,
/// characters and visual elements are perception fields (grounded in frames) and stay untouched.
public actor ScriptAnalysisRefiner {
    private let generator: any ScriptTextGenerating
    private let configuration: GenerationConfig

    public init(
        generator: any ScriptTextGenerating,
        configuration: GenerationConfig = GenerationConfig(temperature: 0.3, topP: 0.9, maxTokens: 1_200)
    ) {
        self.generator = generator
        self.configuration = configuration
    }

    public init(
        engine: any LLMEngine,
        model: ModelIdentity? = nil,
        configuration: GenerationConfig = GenerationConfig(temperature: 0.3, topP: 0.9, maxTokens: 1_200)
    ) {
        self.init(
            generator: LLMTextScriptGenerator(
                engine: engine,
                model: model,
                systemPrompt: "你是短视频剧本分析师，只输出要求的 JSON。"
            ),
            configuration: configuration
        )
    }

    /// Returns the script with re-analyzed title/summary/hookStructure; throws on generation
    /// failure and returns the original when the model output cannot be parsed into anything
    /// substantive (never silently replaces good analysis with an empty shell).
    public func refine(_ script: Script) async throws -> Script {
        let output = try await generator.generateScriptText(
            prompt: Self.prompt(for: script),
            config: configuration
        )
        return Self.applying(output, to: script)
    }

    static func prompt(for script: Script) -> String {
        let shots = script.shots.sorted { $0.index < $1.index }
        let lines = shots.map { shot -> String in
            let narration = shot.narration?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let captions = shot.onScreenText.joined(separator: " / ")
            var parts = ["[\(format(shot.startSeconds))s-\(format(shot.endSeconds))s]"]
            if !narration.isEmpty { parts.append("台词:\(narration)") }
            if !captions.isEmpty { parts.append("字幕:\(captions)") }
            if !shot.visualDescription.isEmpty { parts.append("画面:\(String(shot.visualDescription.prefix(40)))") }
            return parts.joined(separator: " ")
        }.joined(separator: "\n")

        let context = script.userContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let contextBlock = context.isEmpty
            ? "（无。请仅从台词/字幕/画面推断。）"
            : context

        return """
        请基于下面这条短视频的分镜事实，重新分析它的爆款结构。只输出一个合法 JSON 对象，不要 Markdown，不要解释：
        {
          "title": "中文标题",
          "summary": "一句中文摘要",
          "hookStructure": {
            "openingHook": "前 3 秒钩子",
            "hookType": "悬念/共鸣/反差/痛点/利益前置/好奇/身份认同/情绪冲击/其他 之一",
            "retentionDevices": ["留人手法"],
            "payoff": "爆点/反转；注意很多梗视频把爆点放在最后一句的反转里",
            "callToAction": "CTA，可为空",
            "whyItWorks": "为什么可能爆、为什么成立"
          }
        }
        要求：
        - 台词与字幕是权威事实；【背景说明】是作者本人补充的上下文，理解剧情时必须充分采用；
        - 可以运用你对公开人物、战队、赛事、影视作品的常识来识别台词/字幕/背景中指向的真实名称——识别不是编造，只在有明确指向时使用；
        - 通读全部台词到最后一句再判断爆点：结尾的反转、点题或吐槽往往才是真正的爆点；
        - 不要引用台词/字幕/背景之外不存在的情节。

        背景说明：
        \(contextBlock)

        分镜事实：
        \(lines)
        """
    }

    static func applying(_ output: String, to script: Script) -> Script {
        guard let data = JSONEnvelope.slice(output, open: "{", close: "}"),
              let payload = try? JSONDecoder().decode(RefinedAnalysis.self, from: data)
        else {
            Log.scriptComposer.warning("Script re-analysis output unparseable; keeping existing analysis")
            return script
        }

        let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Only substantive output replaces existing analysis — an empty echo keeps the original.
        guard payload.hookStructure != nil || !title.isEmpty || !summary.isEmpty else {
            return script
        }

        return Script(
            id: script.id,
            videoSourceID: script.videoSourceID,
            title: title.isEmpty ? script.title : title,
            summary: summary.isEmpty ? script.summary : summary,
            shots: script.shots,
            createdAt: script.createdAt,
            hookStructure: payload.hookStructure ?? script.hookStructure,
            visualElements: script.visualElements,
            characters: script.characters,
            degradationNote: script.degradationNote,
            userContext: script.userContext
        )
    }
}

private struct RefinedAnalysis: Decodable {
    let title: String?
    let summary: String?
    let hookStructure: HookAnalysis?
}

private func format(_ seconds: Double) -> String {
    String(format: "%.1f", seconds.isFinite ? seconds : 0)
}
