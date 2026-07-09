import Foundation
import ScriptCore

/// A selectable 分镜剧本 in the 洞察 picker.
public struct BreakdownItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let createdAt: Date

    public init(id: String, title: String, summary: String, createdAt: Date) {
        self.id = id
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
    }
}

/// Closures the shell injects so InsightFeature stays free of Infrastructure: breakdowns come from
/// the store, paradigm distillation / application run on the active LLM engine, and paradigms are
/// persisted by the shell.
public struct InsightClient: Sendable {
    public let loadBreakdowns: @Sendable () async -> [BreakdownItem]
    public let generateParadigm: @Sendable (_ clipIDs: [String], _ scopeDescription: String) async -> ScriptParadigm?
    public let loadParadigms: @Sendable () async -> [ScriptParadigm]
    public let saveParadigm: @Sendable (ScriptParadigm) async -> Void
    public let deleteParadigm: @Sendable (_ id: String) async -> Void
    public let applyParadigm: @Sendable (ScriptParadigm, _ topic: String) async -> String?

    public init(
        loadBreakdowns: @escaping @Sendable () async -> [BreakdownItem] = { [] },
        generateParadigm: @escaping @Sendable (_ clipIDs: [String], _ scopeDescription: String) async -> ScriptParadigm? = { _, _ in nil },
        loadParadigms: @escaping @Sendable () async -> [ScriptParadigm] = { [] },
        saveParadigm: @escaping @Sendable (ScriptParadigm) async -> Void = { _ in },
        deleteParadigm: @escaping @Sendable (_ id: String) async -> Void = { _ in },
        applyParadigm: @escaping @Sendable (ScriptParadigm, _ topic: String) async -> String? = { _, _ in nil }
    ) {
        self.loadBreakdowns = loadBreakdowns
        self.generateParadigm = generateParadigm
        self.loadParadigms = loadParadigms
        self.saveParadigm = saveParadigm
        self.deleteParadigm = deleteParadigm
        self.applyParadigm = applyParadigm
    }

    public static let empty = InsightClient()
}
