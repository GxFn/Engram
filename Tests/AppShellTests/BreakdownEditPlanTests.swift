import Foundation
import ScriptCore
import Testing
@testable import AppShell

private func fixtureScript() -> Script {
    Script(
        id: "s", videoSourceID: "v", title: "旧标题", summary: "旧摘要",
        shots: [
            StoryboardShot(index: 0, startSeconds: 0, endSeconds: 3, narration: "旧台词0", visualDescription: "画0"),
            StoryboardShot(index: 1, startSeconds: 3, endSeconds: 6, narration: "旧台词1", visualDescription: "画1", onScreenText: ["字幕1"]),
        ],
        createdAt: Date(timeIntervalSince1970: 0),
        hookStructure: HookAnalysis(openingHook: "旧钩子", retentionDevices: ["旧留人"], payoff: nil, callToAction: nil, whyItWorks: "旧成立"),
        userContext: "旧背景"
    )
}

@Test func breakdownEditPlanAppliesPartialHookNarrationAndContext() throws {
    // The chat's correction block only carries the keys it changes — everything else must survive.
    let raw = """
    {"note":"改爆点与分镜2台词","userContext":"电竞梗：Peyz 转会 T1","hook":{"payoff":"最后一句反转","hookType":"反差"},"narration":[{"shot":2,"text":"什么叫四个陪玩，得等老板"}]}
    """
    let plan = try BreakdownEditPlan.decode(fromJSON: raw)
    #expect(plan.isSubstantive)

    let updated = plan.applied(to: fixtureScript())

    #expect(updated.hookStructure?.payoff == "最后一句反转")     // changed
    #expect(updated.hookStructure?.hookType == .contrast)       // fuzzy string → case
    #expect(updated.hookStructure?.openingHook == "旧钩子")      // untouched hook field survives
    #expect(updated.shots[1].narration == "什么叫四个陪玩，得等老板") // 1-based shot number → index 1
    #expect(updated.shots[0].narration == "旧台词0")
    #expect(updated.userContext == "电竞梗：Peyz 转会 T1")
    #expect(updated.title == "旧标题")                           // absent keys untouched
    #expect(updated.shots[1].onScreenText == ["字幕1"])          // captions survive
}

@Test func breakdownEditPlanToleratesProseAroundJSONAndRejectsEmpty() throws {
    let wrapped = "好的，修正如下：\n```json\n{\"note\":\"改标题\",\"title\":\"新标题\"}\n```"
    let plan = try BreakdownEditPlan.decode(fromJSON: wrapped)
    #expect(plan.applied(to: fixtureScript()).title == "新标题")

    let empty = try BreakdownEditPlan.decode(fromJSON: "{\"note\":\"没改什么\"}")
    #expect(empty.isSubstantive == false)

    #expect(throws: BreakdownEditError.self) {
        _ = try BreakdownEditPlan.decode(fromJSON: "完全不是 JSON")
    }
}

@Test func breakdownFactsRenderingIsOneBasedAndCarriesCaptions() {
    let facts = BreakdownFactsRendering.facts(for: fixtureScript())
    #expect(facts.contains("分镜1"))
    #expect(facts.contains("分镜2"))
    #expect(facts.contains("字幕:字幕1"))
    #expect(facts.contains("背景（用户提供）：旧背景"))
}
