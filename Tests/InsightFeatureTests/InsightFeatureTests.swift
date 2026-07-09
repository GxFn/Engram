import Foundation
import ScriptCore
import Testing
@testable import InsightFeature

@Test func hookTypeMapsChineseEnglishAndUnknown() {
    #expect(HookType.from("悬念") == .suspense)
    #expect(HookType.from("suspense") == .suspense)
    #expect(HookType.from("  情绪冲击 ") == .emotionalShock)
    #expect(HookType.from("乱写的类型") == .other)
    #expect(HookType.from("") == .other)
}

@MainActor
@Test func insightSelectsAndDistillsParadigm() async {
    let breakdowns = [
        BreakdownItem(id: "1", title: "A", summary: "s1", createdAt: Date(timeIntervalSince1970: 2)),
        BreakdownItem(id: "2", title: "B", summary: "s2", createdAt: Date(timeIntervalSince1970: 1)),
    ]
    let paradigm = ScriptParadigm(
        id: "p1",
        name: "校园反差范式",
        applicableScene: "校园",
        sourceClipIDs: ["1", "2"],
        createdAt: Date(timeIntervalSince1970: 0),
        beats: [ParadigmBeat(stage: "开场", pattern: "悬念开场", note: "勾好奇")],
        keyElements: ["校园"]
    )
    let store = ParadigmStore()
    let viewModel = InsightViewModel(client: InsightClient(
        loadBreakdowns: { breakdowns },
        generateParadigm: { ids, _ in ids == ["1", "2"] ? paradigm : nil },
        loadParadigms: { await store.all() },
        saveParadigm: { await store.save($0) },
        deleteParadigm: { await store.delete($0) }
    ))
    await viewModel.load()

    #expect(viewModel.breakdowns.count == 2)
    viewModel.toggleSelection("1")
    viewModel.toggleSelection("2")
    #expect(viewModel.canGenerate)

    let generated = await viewModel.generateParadigm()
    #expect(generated?.id == "p1")
    #expect(viewModel.paradigms.map(\.id) == ["p1"])
    #expect(viewModel.selectedIDs.isEmpty)
    #expect(await store.all().map(\.id) == ["p1"])

    await viewModel.deleteParadigm(paradigm)
    #expect(viewModel.paradigms.isEmpty)
    #expect(await store.all().isEmpty)
}

@MainActor
@Test func insightNeedsTwoSelectionsToDistill() async {
    let viewModel = InsightViewModel(client: InsightClient(
        loadBreakdowns: { [BreakdownItem(id: "1", title: "A", summary: "", createdAt: Date())] }
    ))
    await viewModel.load()
    viewModel.toggleSelection("1")

    #expect(!viewModel.canGenerate)
    let paradigm = await viewModel.generateParadigm()
    #expect(paradigm == nil)
    #expect(viewModel.errorMessage != nil)
}

@MainActor
@Test func insightAppliesParadigmToTopic() async {
    let paradigm = ScriptParadigm(id: "p", name: "n", applicableScene: "", sourceClipIDs: [], createdAt: Date(), beats: [], keyElements: [])
    let viewModel = InsightViewModel(client: InsightClient(
        applyParadigm: { _, topic in "剧本骨架 for \(topic)" }
    ))

    let scaffold = await viewModel.apply(paradigm, topic: "租房避坑")
    #expect(scaffold == "剧本骨架 for 租房避坑")
}

private actor ParadigmStore {
    private var items: [ScriptParadigm] = []
    func all() -> [ScriptParadigm] { items }
    func save(_ paradigm: ScriptParadigm) {
        items.removeAll { $0.id == paradigm.id }
        items.insert(paradigm, at: 0)
    }
    func delete(_ id: String) { items.removeAll { $0.id == id } }
}
