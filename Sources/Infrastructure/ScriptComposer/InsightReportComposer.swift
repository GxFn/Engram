import EngineKit
import EngramLogging
import Foundation
import ScriptCore

/// Cross-video insight (v6 P3): map-reduce over the hook library. "Map" is already done (each hook
/// is structured), so this only feeds the LLM a compact structured summary (not raw video / full
/// text) — cheap — and parses a structured report back, mapping evidence indices to source clip
/// ids. Returns nil (never throws except on cancellation) so the UI degrades gracefully.
public actor InsightReportComposer {
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
                systemPrompt: "你是短视频方法论分析师，只做跨视频归纳，只输出要求的 JSON。"
            ),
            configuration: configuration
        )
    }

    public func compose(hooks: [HookEntry], scopeDescription: String) async throws -> InsightReport? {
        guard hooks.count >= 2 else {
            return nil // need a corpus to find cross-video patterns
        }
        do {
            let output = try await generator.generateScriptText(
                prompt: Self.prompt(hooks: hooks, scope: scopeDescription),
                config: configuration
            )
            return Self.parse(
                output,
                hooks: hooks,
                scopeDescription: scopeDescription,
                createdAt: dateProvider(),
                id: idProvider()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.scriptComposer.error(
                "Insight report generation failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    static func prompt(hooks: [HookEntry], scope: String) -> String {
        let lines = hooks.enumerated().map { index, hook in
            let devices = hook.retentionDevices.joined(separator: "、")
            return "[\(index)] 类型:\(hook.hookType.displayName) | 钩子:\(hook.text) | 留人:\(devices) | 为什么:\(hook.whyItWorks) | 来源:\(hook.clipTitle)"
        }.joined(separator: "\n")

        return """
        你是短视频方法论分析师。下面是我拆解过的 \(hooks.count) 条视频的开场钩子（已结构化）。请在这批语料上做跨视频归纳，帮我看懂"这一类为什么爆"以及"我该怎么起号"。
        只输出一个合法 JSON 对象，不要 Markdown、不要解释。结构：
        {
          "title": "一句话报告标题",
          "sections": [
            {"heading": "钩子套路", "body": "归纳这批最常见的开场套路与规律", "evidence": [引用的条目编号数字数组]},
            {"heading": "留人手法", "body": "高频留人手法及其作用", "evidence": []},
            {"heading": "为什么成立的共性", "body": "这批共同的底层原因", "evidence": []},
            {"heading": "选题聚类", "body": "主题上的分组", "evidence": []},
            {"heading": "可复用建议", "body": "如果我要做这一类，开场/留人/爆点该怎么设计的具体建议", "evidence": []}
          ]
        }
        要求：body 具体、可执行，不要泛泛而谈；每个 section 的 evidence 用上面的条目编号（数字数组）指出依据；只基于给定语料，不要编造语料外的内容。

        语料：
        \(lines)
        """
    }

    static func parse(
        _ output: String,
        hooks: [HookEntry],
        scopeDescription: String,
        createdAt: Date,
        id: String
    ) -> InsightReport? {
        guard let data = extractJSONObject(from: output),
              let payload = try? JSONDecoder().decode(ReportPayload.self, from: data)
        else {
            return nil
        }

        let sections = payload.sections.compactMap { section -> InsightSection? in
            let heading = section.heading.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heading.isEmpty, !body.isEmpty else {
                return nil
            }
            var evidence: [String] = []
            var seen = Set<String>()
            for index in section.evidence where index >= 0 && index < hooks.count {
                let clipID = hooks[index].clipID
                if seen.insert(clipID).inserted {
                    evidence.append(clipID)
                }
            }
            return InsightSection(heading: heading, body: body, evidenceClipIDs: evidence)
        }
        guard !sections.isEmpty else {
            return nil
        }

        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return InsightReport(
            id: id,
            title: title.isEmpty ? "跨视频洞察" : title,
            scopeDescription: scopeDescription,
            sourceCount: hooks.count,
            createdAt: createdAt,
            sections: sections
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

private struct ReportPayload: Decodable {
    let title: String
    let sections: [SectionPayload]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        sections = try container.decodeIfPresent([SectionPayload].self, forKey: .sections) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case title, sections
    }
}

private struct SectionPayload: Decodable {
    let heading: String
    let body: String
    let evidence: [Int]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        heading = try container.decodeIfPresent(String.self, forKey: .heading) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        evidence = (try? container.decode([Int].self, forKey: .evidence)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case heading, body, evidence
    }
}
