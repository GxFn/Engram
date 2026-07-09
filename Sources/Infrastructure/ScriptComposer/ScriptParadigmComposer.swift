import EngineKit
import EngramLogging
import Foundation
import ScriptCore

/// Distills a reusable 剧本范式 from several 分镜剧本 (map-reduce over structured breakdowns, not raw
/// video — cheap), and applies a paradigm to a new topic to produce a fresh script scaffold. The
/// apply step is judgment assistance (a structural scaffold in text), never video generation.
/// Returns nil on failure (except cancellation) so the UI degrades gracefully.
public actor ScriptParadigmComposer {
    private let generator: any ScriptTextGenerating
    private let configuration: GenerationConfig
    private let dateProvider: @Sendable () -> Date
    private let idProvider: @Sendable () -> String

    public init(
        generator: any ScriptTextGenerating,
        configuration: GenerationConfig = GenerationConfig(temperature: 0.3, topP: 0.9, maxTokens: 1_500),
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
        configuration: GenerationConfig = GenerationConfig(temperature: 0.3, topP: 0.9, maxTokens: 1_500)
    ) {
        self.init(
            generator: LLMTextScriptGenerator(
                engine: engine,
                model: model,
                systemPrompt: "你是短视频剧本方法论分析师，只做跨剧本归纳，只输出要求的 JSON。"
            ),
            configuration: configuration
        )
    }

    /// Distills a paradigm from selected breakdowns.
    public func compose(sources: [ParadigmSource], scopeDescription: String) async throws -> ScriptParadigm? {
        guard sources.count >= 2 else {
            return nil // need at least two scripts to find a shared paradigm
        }
        do {
            let output = try await generator.generateScriptText(
                prompt: Self.distillPrompt(sources: sources),
                config: configuration
            )
            return Self.parseParadigm(
                output,
                sources: sources,
                createdAt: dateProvider(),
                id: idProvider()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.scriptComposer.error(
                "Paradigm distillation failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Applies a paradigm to a new topic → a fresh script scaffold (readable text). Judgment
    /// assistance: structure/台词 direction, not video generation.
    public func apply(paradigm: ScriptParadigm, topic: String) async throws -> String? {
        let cleanTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTopic.isEmpty else {
            return nil
        }
        do {
            let output = try await generator.generateScriptText(
                prompt: Self.applyPrompt(paradigm: paradigm, topic: cleanTopic),
                config: GenerationConfig(temperature: 0.6, topP: 0.9, maxTokens: 1_500)
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.scriptComposer.error(
                "Paradigm apply failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    static func distillPrompt(sources: [ParadigmSource]) -> String {
        let lines = sources.enumerated().map { index, source -> String in
            let hookType = source.hook?.hookType.displayName ?? "未知"
            let hook = source.hook?.openingHook ?? ""
            let retention = source.hook?.retentionDevices.joined(separator: "、") ?? ""
            return "[\(index)] 标题:\(source.title) | 摘要:\(source.summary) | 钩子类型:\(hookType) | 钩子:\(hook) | 留人:\(retention) | 分镜数:\(source.shotCount)"
        }.joined(separator: "\n")

        return """
        你是短视频剧本方法论分析师。下面是我拆解过的 \(sources.count) 条爆款视频的分镜剧本（已结构化）。请提炼出它们共同的、可复用的"剧本范式"——一套我能直接套用去起号的模板，而不是逐条分析。
        只输出一个合法 JSON 对象，不要 Markdown、不要解释。结构：
        {
          "name": "范式名称（一句话，如“校园反差爆款范式”）",
          "applicableScene": "适用场景（什么题材/风格适合套这套）",
          "beats": [
            {"stage": "开场钩子", "pattern": "这一段的可复用套路", "note": "要点/为什么这样有效"},
            {"stage": "留人", "pattern": "", "note": ""},
            {"stage": "爆点", "pattern": "", "note": ""},
            {"stage": "收尾", "pattern": "", "note": ""}
          ],
          "keyElements": ["跨这批共有的关键要素：人物/场景/节奏/风格，3-6 个"]
        }
        要求：pattern 与 note 要具体、可执行、能直接套用；只基于给定剧本归纳共性，不要编造语料外的内容。

        剧本：
        \(lines)
        """
    }

    static func applyPrompt(paradigm: ScriptParadigm, topic: String) -> String {
        let beats = paradigm.beats
            .map { "- \($0.stage)：\($0.pattern)（\($0.note)）" }
            .joined(separator: "\n")
        let elements = paradigm.keyElements.joined(separator: "、")

        return """
        下面是一套我从爆款里提炼的剧本范式，请把它套用到我的新主题上，产出一版可直接拍的分镜剧本骨架。
        只产出文字剧本骨架（分镜、台词方向、画面提示），不要生成或描述成品视频，不要解释。

        范式：\(paradigm.name)（\(paradigm.applicableScene)）
        结构：
        \(beats)
        关键要素：\(elements)

        我的新主题：\(topic)

        请按范式的结构，逐个分镜给出：时间/景别、画面提示、台词或旁白方向、这一段套用了范式的哪条。语言简洁可执行。
        """
    }

    static func parseParadigm(
        _ output: String,
        sources: [ParadigmSource],
        createdAt: Date,
        id: String
    ) -> ScriptParadigm? {
        guard let data = extractJSONObject(from: output),
              let payload = try? JSONDecoder().decode(ParadigmPayload.self, from: data)
        else {
            return nil
        }

        let beats = payload.beats.compactMap { beat -> ParadigmBeat? in
            let stage = beat.stage.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = beat.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stage.isEmpty, !pattern.isEmpty else {
                return nil
            }
            return ParadigmBeat(
                stage: stage,
                pattern: pattern,
                note: beat.note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard !beats.isEmpty else {
            return nil
        }

        let elements = payload.keyElements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)

        return ScriptParadigm(
            id: id,
            name: name.isEmpty ? "剧本范式" : name,
            applicableScene: payload.applicableScene.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceClipIDs: sources.map(\.clipID),
            createdAt: createdAt,
            beats: beats,
            keyElements: elements
        )
    }

    private static func extractJSONObject(from output: String) -> Data? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else {
            return nil
        }
        return Data(trimmed[start ... end].utf8)
    }
}

private struct ParadigmPayload: Decodable {
    let name: String
    let applicableScene: String
    let beats: [BeatPayload]
    let keyElements: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        applicableScene = try container.decodeIfPresent(String.self, forKey: .applicableScene) ?? ""
        beats = try container.decodeIfPresent([BeatPayload].self, forKey: .beats) ?? []
        keyElements = try container.decodeIfPresent([String].self, forKey: .keyElements) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case name, applicableScene, beats, keyElements
    }
}

private struct BeatPayload: Decodable {
    let stage: String
    let pattern: String
    let note: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = try container.decodeIfPresent(String.self, forKey: .stage) ?? ""
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case stage, pattern, note
    }
}
