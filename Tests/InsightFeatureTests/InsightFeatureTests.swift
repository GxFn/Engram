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

@Test func hookTypeDecodesLenientlyFromChineseLabel() throws {
    let json = #"{"hookType":"反差"}"#
    struct Wrapper: Decodable { let hookType: HookType }
    let decoded = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
    #expect(decoded.hookType == .contrast)
}

@Test func hookEntryDerivesPrimaryHookFromBreakdown() {
    let script = Script(
        id: "s",
        videoSourceID: "v",
        title: "T",
        summary: "S",
        shots: [StoryboardShot(index: 0, startSeconds: 0, endSeconds: 1, visualDescription: "画面")],
        createdAt: Date(timeIntervalSince1970: 100),
        hookStructure: HookAnalysis(
            openingHook: "前3秒的悬念钩子",
            retentionDevices: ["制造信息差"],
            whyItWorks: "利用好奇心",
            hookType: .suspense
        )
    )
    let entry = HookEntry.derive(clipID: "clip", clipTitle: "标题", createdAt: Date(timeIntervalSince1970: 200), script: script)
    #expect(entry?.text == "前3秒的悬念钩子")
    #expect(entry?.hookType == .suspense)
    #expect(entry?.clipID == "clip")
    #expect(entry?.retentionDevices == ["制造信息差"])
}

@Test func hookEntryDeriveReturnsNilWithoutHook() {
    let script = Script(id: "s", videoSourceID: "v", title: "T", summary: "S", shots: [], createdAt: Date())
    #expect(HookEntry.derive(clipID: "c", clipTitle: "t", createdAt: Date(), script: script) == nil)
}

@MainActor
@Test func hookLibraryFiltersByTypeFavoriteAndKeyword() async {
    let entries = [
        makeEntry(id: "1", title: "A", text: "关于减肥的悬念开场", type: .suspense, favorite: true),
        makeEntry(id: "2", title: "B", text: "身材焦虑的共鸣", type: .resonance, favorite: false),
    ]
    let viewModel = HookLibraryViewModel(client: HookLibraryClient(loadHooks: { entries }))
    await viewModel.load()

    #expect(viewModel.hooks.count == 2)
    #expect(viewModel.presentTypes == [.suspense, .resonance])

    viewModel.selectedType = .suspense
    #expect(viewModel.filtered.map(\.id) == ["1"])

    viewModel.selectedType = nil
    viewModel.favoritesOnly = true
    #expect(viewModel.filtered.map(\.id) == ["1"])

    viewModel.favoritesOnly = false
    viewModel.searchText = "共鸣"
    #expect(viewModel.filtered.map(\.id) == ["2"])
}

@MainActor
@Test func hookLibraryToggleFavoriteIsOptimisticAndPersists() async {
    let recorder = FavoriteRecorder()
    let entries = [makeEntry(id: "1", title: "A", text: "x", type: .other, favorite: false)]
    let viewModel = HookLibraryViewModel(client: HookLibraryClient(
        loadHooks: { entries },
        setFavorite: { clipID, isFavorite in await recorder.record(clipID, isFavorite) }
    ))
    await viewModel.load()

    await viewModel.toggleFavorite(viewModel.hooks[0])

    #expect(viewModel.hooks[0].isFavorite == true)
    #expect(await recorder.calls == [FavoriteCall(clipID: "1", isFavorite: true)])
}

@MainActor
@Test func hookLibraryDashboardAggregatesTypesAndDevices() async {
    let entries = [
        makeEntry(id: "1", title: "A", text: "x", type: .suspense, favorite: false, devices: ["制造悬念", "信息差"]),
        makeEntry(id: "2", title: "B", text: "y", type: .suspense, favorite: false, devices: ["制造悬念"]),
        makeEntry(id: "3", title: "C", text: "z", type: .resonance, favorite: false, devices: ["情绪共鸣"]),
    ]
    let viewModel = HookLibraryViewModel(client: HookLibraryClient(loadHooks: { entries }))
    await viewModel.load()

    #expect(viewModel.totalHooks == 3)
    #expect(viewModel.typeDistribution.map { TypePair(type: $0.type, count: $0.count) }
        == [TypePair(type: .suspense, count: 2), TypePair(type: .resonance, count: 1)])

    let top = viewModel.topRetentionDevices()
    #expect(top.first?.label == "制造悬念")
    #expect(top.first?.count == 2)
}

private struct TypePair: Equatable {
    let type: HookType
    let count: Int
}

@MainActor
@Test func hookLibraryGeneratesSavesAndDeletesReport() async {
    let entries = [
        makeEntry(id: "1", title: "A", text: "x", type: .suspense, favorite: false),
        makeEntry(id: "2", title: "B", text: "y", type: .resonance, favorite: false),
    ]
    let report = InsightReport(
        id: "r1",
        title: "报告",
        scopeDescription: "全部 · 2 条",
        sourceCount: 2,
        createdAt: Date(timeIntervalSince1970: 0),
        sections: [InsightSection(heading: "钩子套路", body: "归纳", evidenceClipIDs: ["1"])]
    )
    let store = ReportStore()
    let viewModel = HookLibraryViewModel(client: HookLibraryClient(
        loadHooks: { entries },
        generateReport: { _, _ in report },
        loadReports: { await store.all() },
        saveReport: { await store.save($0) },
        deleteReport: { await store.delete($0) }
    ))
    await viewModel.load()

    let generated = await viewModel.generateReport()
    #expect(generated?.id == "r1")
    #expect(viewModel.reports.map(\.id) == ["r1"])
    #expect(await store.all().map(\.id) == ["r1"])

    await viewModel.deleteReport(report)
    #expect(viewModel.reports.isEmpty)
    #expect(await store.all().isEmpty)
}

@MainActor
@Test func hookLibraryGenerateReportNeedsAtLeastTwoHooks() async {
    let viewModel = HookLibraryViewModel(client: HookLibraryClient(
        loadHooks: { [makeEntry(id: "1", title: "A", text: "x", type: .other, favorite: false)] }
    ))
    await viewModel.load()

    let report = await viewModel.generateReport()

    #expect(report == nil)
    #expect(viewModel.reportError != nil)
}

private actor ReportStore {
    private var reports: [InsightReport] = []
    func all() -> [InsightReport] { reports }
    func save(_ report: InsightReport) {
        reports.removeAll { $0.id == report.id }
        reports.insert(report, at: 0)
    }
    func delete(_ id: String) { reports.removeAll { $0.id == id } }
}

private func makeEntry(
    id: String,
    title: String,
    text: String,
    type: HookType,
    favorite: Bool,
    devices: [String] = []
) -> HookEntry {
    HookEntry(
        id: id,
        clipID: id,
        clipTitle: title,
        text: text,
        hookType: type,
        retentionDevices: devices,
        payoff: nil,
        whyItWorks: "",
        createdAt: Date(timeIntervalSince1970: 0),
        isFavorite: favorite
    )
}

private struct FavoriteCall: Equatable {
    let clipID: String
    let isFavorite: Bool
}

private actor FavoriteRecorder {
    private(set) var calls: [FavoriteCall] = []
    func record(_ clipID: String, _ isFavorite: Bool) {
        calls.append(FavoriteCall(clipID: clipID, isFavorite: isFavorite))
    }
}
