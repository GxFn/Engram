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

private func makeEntry(id: String, title: String, text: String, type: HookType, favorite: Bool) -> HookEntry {
    HookEntry(
        id: id,
        clipID: id,
        clipTitle: title,
        text: text,
        hookType: type,
        retentionDevices: [],
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
