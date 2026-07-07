import Foundation
import Testing
import VideoUnderstanding
@testable import ScriptCore

@Test func scriptRoundTripsThroughCodable() throws {
    let script = Script(
        id: "script-1",
        videoSourceID: "video-1",
        title: "Launch Plan",
        summary: "A concise product launch storyboard.",
        shots: [
            StoryboardShot(
                index: 0,
                startSeconds: 0,
                endSeconds: 4.5,
                narration: "Here is the setup.",
                visualDescription: "Phone on desk with the app open.",
                pacingNote: "Calm open"
            )
        ],
        createdAt: Date(timeIntervalSince1970: 1_900)
    )

    let data = try JSONEncoder().encode(script)
    let decoded = try JSONDecoder().decode(Script.self, from: data)
    #expect(decoded == script)
}

@Test func hookAnalysisRoundTripsThroughCodable() throws {
    let hook = HookAnalysis(
        openingHook: "A quiet cooking shot becomes a speed-run reveal.",
        retentionDevices: ["contrast", "open loop", "fast cuts"],
        payoff: "The finished plate appears in one clean cut.",
        callToAction: "Save this structure for your next demo.",
        whyItWorks: "It creates a small mystery, then pays it off with a clear visual transformation."
    )

    let data = try JSONEncoder().encode(hook)
    let decoded = try JSONDecoder().decode(HookAnalysis.self, from: data)

    #expect(decoded == hook)
}

@Test func enrichedScriptRoundTripsThroughCodable() throws {
    let hook = HookAnalysis(
        openingHook: "The first frame promises a surprising before/after.",
        retentionDevices: ["before-after contrast", "captioned open loop"],
        payoff: "The messy desk turns into a clean editing setup.",
        callToAction: nil,
        whyItWorks: "The viewer understands the transformation instantly and waits for the reveal."
    )
    let script = Script(
        id: "script-rich",
        videoSourceID: "video-rich",
        title: "Desk Reset",
        summary: "A compact creator workflow breakdown.",
        shots: [
            StoryboardShot(
                index: 0,
                startSeconds: 0,
                endSeconds: 3,
                narration: "Watch the setup change in one move.",
                visualDescription: "A cluttered desk fills the frame.",
                pacingNote: "Fast hook"
            )
        ],
        createdAt: Date(timeIntervalSince1970: 2_300),
        hookStructure: hook,
        visualElements: ["creator desk", "phone tripod", "jump cut", "clean setup"]
    )

    let data = try JSONEncoder().encode(script)
    let decoded = try JSONDecoder().decode(Script.self, from: data)

    #expect(decoded == script)
    #expect(decoded.hookStructure == hook)
    #expect(decoded.visualElements == ["creator desk", "phone tripod", "jump cut", "clean setup"])
}

@Test func legacyScriptJSONDecodesMissingHookAndVisualFields() throws {
    let legacyJSON = """
    {
      "id": "script-legacy",
      "videoSourceID": "video-legacy",
      "title": "Legacy Script",
      "summary": "Stored before v4 hook fields existed.",
      "shots": [
        {
          "index": 0,
          "startSeconds": 1.0,
          "endSeconds": 4.0,
          "narration": "Old narration",
          "visualDescription": "Old visual",
          "pacingNote": "Old pacing"
        }
      ],
      "createdAt": 2400
    }
    """

    let decoded = try JSONDecoder().decode(Script.self, from: Data(legacyJSON.utf8))

    #expect(decoded.id == "script-legacy")
    #expect(decoded.hookStructure == nil)
    #expect(decoded.visualElements == [])
    #expect(decoded.shots.count == 1)
}

@Test func scriptDefaultsPreserveExistingInitializationHashableAndSendableShape() {
    let script = Script(
        id: "script-defaults",
        videoSourceID: "video-defaults",
        title: "Defaults",
        summary: "Existing callers do not need v4 fields.",
        shots: [],
        createdAt: Date(timeIntervalSince1970: 2_500)
    )

    #expect(script.hookStructure == nil)
    #expect(script.visualElements == [])
    #expect(Set([script, script]).count == 1)
    _ = requireSendable(script)
}

@Test func emptyShotsRenderTitleAndSummaryOnly() {
    let script = Script(
        id: "script-empty",
        videoSourceID: "video-empty",
        title: "Empty Storyboard",
        summary: "No storyboard shots are available yet.",
        shots: [],
        createdAt: Date(timeIntervalSince1970: 2_000)
    )

    #expect(ScriptRendering.indexableText(script) == "Empty Storyboard\n\nNo storyboard shots are available yet.")
}

@Test func enrichedScriptIndexableTextIncludesHookAndVisualBlocksBeforeShots() {
    let script = Script(
        id: "script-rich-render",
        videoSourceID: "video-rich-render",
        title: "爆款拆解",
        summary: "一条先抛悬念再给步骤的视频。",
        shots: [
            StoryboardShot(
                index: 0,
                startSeconds: 1.2,
                endSeconds: 6,
                narration: "先别急着买，三步看懂差别。",
                visualDescription: "手持产品切到桌面对比。",
                pacingNote: "快节奏开场"
            )
        ],
        createdAt: Date(timeIntervalSince1970: 2_800),
        hookStructure: HookAnalysis(
            openingHook: "第一秒直接提出反常识问题。",
            retentionDevices: ["反差画面", "步骤预告", "结果前置"],
            payoff: "最后展示明显的前后对比。",
            callToAction: "收藏这套拆解模板。",
            whyItWorks: "悬念和结果都很具体，用户愿意看完验证。"
        ),
        visualElements: ["人物出镜", "桌面对比", "产品特写", "字幕强调"]
    )

    let paragraphs = ScriptRendering.indexableText(script).components(separatedBy: "\n\n")

    #expect(paragraphs == [
        "爆款拆解",
        "一条先抛悬念再给步骤的视频。",
        "## 爆点结构\n钩子: 第一秒直接提出反常识问题。\n留人: 反差画面、步骤预告、结果前置\n爆点: 最后展示明显的前后对比。\nCTA: 收藏这套拆解模板。\n为什么成立: 悬念和结果都很具体，用户愿意看完验证。",
        "## 视觉元素\n标签: 人物出镜、桌面对比、产品特写、字幕强调",
        "## 分镜 1 (1.2s–6s)\n台词: 先别急着买，三步看懂差别。\n画面: 手持产品切到桌面对比。\n节奏: 快节奏开场",
    ])
}

@Test func missingHookAndVisualElementsDoNotRenderNewIndexableTitles() {
    let script = Script(
        id: "script-no-rich-render",
        videoSourceID: "video-no-rich-render",
        title: "普通脚本",
        summary: "没有 v4 富化字段。",
        shots: [
            StoryboardShot(
                index: 0,
                startSeconds: 0,
                endSeconds: 3,
                narration: "保留原有分镜格式。",
                visualDescription: "一个简单画面。",
                pacingNote: nil
            )
        ],
        createdAt: Date(timeIntervalSince1970: 2_900)
    )

    let text = ScriptRendering.indexableText(script)

    #expect(!text.contains("## 爆点结构"))
    #expect(!text.contains("## 视觉元素"))
    #expect(text.contains("## 分镜 1 (0s–3s)"))
    #expect(text.contains("台词: 保留原有分镜格式。"))
    #expect(text.contains("画面: 一个简单画面。"))
}

@Test func nilPayoffAndCallToActionDoNotRenderOptionalOrEmptyPlaceholders() {
    let script = Script(
        id: "script-partial-hook",
        videoSourceID: "video-partial-hook",
        title: "局部爆点结构",
        summary: "没有爆点和 CTA 字段。",
        shots: [],
        createdAt: Date(timeIntervalSince1970: 3_000),
        hookStructure: HookAnalysis(
            openingHook: "先给一个明确疑问。",
            retentionDevices: ["开放问题"],
            payoff: nil,
            callToAction: nil,
            whyItWorks: "用户会等待答案出现。"
        ),
        visualElements: []
    )

    let text = ScriptRendering.indexableText(script)

    #expect(text.contains("## 爆点结构"))
    #expect(text.contains("钩子: 先给一个明确疑问。"))
    #expect(text.contains("留人: 开放问题"))
    #expect(text.contains("为什么成立: 用户会等待答案出现。"))
    #expect(!text.contains("Optional"))
    #expect(!text.contains("爆点:"))
    #expect(!text.contains("CTA:"))
    #expect(!text.contains("## 视觉元素"))
}

@Test func multipleShotsRenderAsParagraphFriendlyBlocks() {
    let script = Script(
        id: "script-multi",
        videoSourceID: "video-multi",
        title: "Kitchen Demo",
        summary: "A two-shot cooking demo.",
        shots: [
            StoryboardShot(
                index: 1,
                startSeconds: 5,
                endSeconds: 8.25,
                narration: "Then plate the noodles.",
                visualDescription: "A bowl slides into frame.",
                pacingNote: "Quick payoff"
            ),
            StoryboardShot(
                index: 0,
                startSeconds: 0,
                endSeconds: 4,
                narration: "Start with the sauce.",
                visualDescription: "Close-up of sauce simmering.",
                pacingNote: "Warm intro"
            )
        ],
        createdAt: Date(timeIntervalSince1970: 2_100)
    )

    let paragraphs = ScriptRendering.indexableText(script).components(separatedBy: "\n\n")

    #expect(paragraphs == [
        "Kitchen Demo",
        "A two-shot cooking demo.",
        "## 分镜 1 (0s–4s)\n台词: Start with the sauce.\n画面: Close-up of sauce simmering.\n节奏: Warm intro",
        "## 分镜 2 (5s–8.3s)\n台词: Then plate the noodles.\n画面: A bowl slides into frame.\n节奏: Quick payoff"
    ])
}

@Test func missingNarrationDoesNotRenderAnEmptyNarrationLine() {
    let script = Script(
        id: "script-no-narration",
        videoSourceID: "video-no-narration",
        title: "Silent Cutaway",
        summary: "The visual carries the beat.",
        shots: [
            StoryboardShot(
                index: 0,
                startSeconds: 9,
                endSeconds: 12,
                narration: nil,
                visualDescription: "A quiet cutaway to the street outside.",
                pacingNote: nil
            ),
            StoryboardShot(
                index: 1,
                startSeconds: 12,
                endSeconds: 14,
                narration: "  ",
                visualDescription: "The presenter returns to camera.",
                pacingNote: " "
            )
        ],
        createdAt: Date(timeIntervalSince1970: 2_200)
    )

    let text = ScriptRendering.indexableText(script)

    #expect(!text.contains("台词: \n"))
    #expect(!text.contains("台词:  "))
    #expect(!text.contains("节奏: \n"))
    #expect(text.contains("画面: A quiet cutaway to the street outside."))
    #expect(text.contains("画面: The presenter returns to camera."))
}

private func requireSendable<Value: Sendable>(_ value: Value) -> Value {
    value
}
