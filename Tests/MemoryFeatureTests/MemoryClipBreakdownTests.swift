import ClipCore
import Foundation
import MemoryFeature
import ScriptCore
import Testing

@Test func memoryClipDecodesBreakdownAndBuildsHandoffText() throws {
    let script = Script(
        id: "s1",
        videoSourceID: "v1",
        title: "测试标题",
        summary: "测试摘要",
        shots: [
            StoryboardShot(index: 0, startSeconds: 0, endSeconds: 2, narration: "第一句", visualDescription: "画面一", pacingNote: "快"),
        ],
        createdAt: Date(timeIntervalSince1970: 0),
        hookStructure: HookAnalysis(
            openingHook: "开场钩子",
            retentionDevices: ["悬念"],
            payoff: "反转",
            callToAction: "关注",
            whyItWorks: "低门槛高收益"
        ),
        visualElements: ["主角", "厨房"]
    )
    let json = String(decoding: try JSONEncoder().encode(script), as: UTF8.self)
    let clip = makeClip(scriptJSON: json, bodyText: "旧文本")

    let breakdown = try #require(clip.breakdown)
    #expect(breakdown.hookStructure?.openingHook == "开场钩子")
    #expect(breakdown.visualElements == ["主角", "厨房"])
    // handoffText prefers the structured breakdown rendering (fed to 豆包/即梦).
    #expect(clip.handoffText.contains("爆点结构"))
    #expect(clip.handoffText.contains("开场钩子"))
    #expect(clip.handoffText.contains("视觉元素"))
    #expect(clip.handoffText.contains("分镜 1"))
}

@Test func memoryClipFallsBackToBodyTextWhenNoScript() {
    let clip = makeClip(scriptJSON: nil, bodyText: "纯文本内容")
    #expect(clip.breakdown == nil)
    #expect(clip.handoffText == "纯文本内容")
}

@Test func memoryClipWithMalformedScriptJSONFallsBack() {
    let clip = makeClip(scriptJSON: "{ not valid json", bodyText: "回退文本")
    #expect(clip.breakdown == nil)
    #expect(clip.handoffText == "回退文本")
}

private func makeClip(scriptJSON: String?, bodyText: String?) -> MemoryClip {
    MemoryClip(
        id: "c1",
        title: "测试标题",
        sourceURL: nil,
        note: nil,
        bodyText: bodyText,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        state: .indexed,
        failureReason: nil,
        failureRetryable: false,
        indexPreview: nil,
        scriptJSON: scriptJSON
    )
}

@Test func displayTitlePrefersBreakdownTitleOverUUIDImportName() throws {
    // PHPicker imports store a UUID temp filename as the title — meaningless in lists. The
    // breakdown's AI title is the real name; a human-set title always wins.
    let script = Script(
        id: "s", videoSourceID: "v", title: "电竞转会梗视频", summary: "s",
        shots: [StoryboardShot(index: 0, startSeconds: 0, endSeconds: 3, narration: "词", visualDescription: "画")],
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let json = try #require(ScriptCoding.encode(script))

    func clip(title: String, scriptJSON: String?) -> MemoryClip {
        MemoryClip(
            id: "c", title: title, sourceURL: nil, note: nil, bodyText: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            state: .indexed, failureReason: nil, failureRetryable: false, indexPreview: nil,
            scriptJSON: scriptJSON, sourceKind: .video
        )
    }

    #expect(clip(title: "B454DEFD-A311-4290-9236-BF42469B84CC", scriptJSON: json).displayTitle == "电竞转会梗视频")
    #expect(clip(title: "我自己起的名字", scriptJSON: json).displayTitle == "我自己起的名字")
    #expect(clip(title: "B454DEFD-A311-4290-9236-BF42469B84CC", scriptJSON: nil).displayTitle == "B454DEFD-A311-4290-9236-BF42469B84CC")
}
