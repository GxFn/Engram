import Foundation
import Observation
import ScriptCore

@MainActor
@Observable
public final class InsightViewModel {
    public private(set) var breakdowns: [BreakdownItem] = []
    public var selectedIDs: Set<String> = []
    public private(set) var paradigms: [ScriptParadigm] = []
    public private(set) var isGenerating = false
    public var errorMessage: String?

    @ObservationIgnored private let client: InsightClient

    public init(client: InsightClient = .empty) {
        self.client = client
    }

    public func load() async {
        breakdowns = await client.loadBreakdowns()
        paradigms = await client.loadParadigms()
    }

    public func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    public var canGenerate: Bool {
        selectedIDs.count >= 2 && !isGenerating
    }

    /// Distills a paradigm from the selected breakdowns, saves it, and returns it.
    @discardableResult
    public func generateParadigm() async -> ScriptParadigm? {
        guard !isGenerating else {
            return nil
        }
        guard selectedIDs.count >= 2 else {
            errorMessage = "至少选 2 条剧本才能提炼出可复用的范式。"
            return nil
        }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        // Preserve library order for stable, readable evidence.
        let orderedIDs = breakdowns.map(\.id).filter { selectedIDs.contains($0) }
        guard let paradigm = await client.generateParadigm(orderedIDs) else {
            errorMessage = "提炼失败，请重试。"
            return nil
        }
        await client.saveParadigm(paradigm)
        paradigms.insert(paradigm, at: 0)
        selectedIDs.removeAll()
        return paradigm
    }

    public func deleteParadigm(_ paradigm: ScriptParadigm) async {
        paradigms.removeAll { $0.id == paradigm.id }
        await client.deleteParadigm(paradigm.id)
    }

    public func apply(_ paradigm: ScriptParadigm, topic: String) async -> String? {
        await client.applyParadigm(paradigm, topic)
    }

    public func title(forClip clipID: String) -> String? {
        breakdowns.first { $0.id == clipID }?.title
    }
}
