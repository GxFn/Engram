import Foundation

public struct BenchPrompt: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct BenchPromptSuite: Sendable, Hashable, Codable {
    public let prompts: [BenchPrompt]

    public init(prompts: [BenchPrompt]) {
        self.prompts = prompts
    }

    public static func bundled() throws -> BenchPromptSuite {
        try bundled(bundle: .module)
    }

    public static func bundled(bundle: Bundle) throws -> BenchPromptSuite {
        guard let url = bundle.url(
            forResource: "prompts",
            withExtension: "json",
            subdirectory: "BenchSuite"
        ) else {
            return builtIn
        }

        return try load(from: url)
    }

    public static func load(from url: URL) throws -> BenchPromptSuite {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BenchPromptSuite.self, from: data)
    }

    public static let builtIn = BenchPromptSuite(prompts: [
        BenchPrompt(id: "zh-summary", text: "用三句话总结今天保存的剪藏重点。"),
        BenchPrompt(id: "en-questions", text: "List three questions this note should help answer later."),
        BenchPrompt(id: "zh-action", text: "从这些内容里提取两个可以立刻执行的行动项。"),
        BenchPrompt(id: "en-compare", text: "Compare the strongest and weakest claim in the passage."),
        BenchPrompt(id: "zh-counter", text: "指出这段材料可能遗漏的一个反例。"),
        BenchPrompt(id: "en-outline", text: "Create a concise outline for a five-minute briefing."),
        BenchPrompt(id: "zh-memory", text: "把这条记忆改写成适合一周后复习的提示。"),
        BenchPrompt(id: "en-risk", text: "Name one risk, one assumption, and one follow-up question."),
    ])
}
