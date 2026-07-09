import Foundation
import ScriptCore
import Testing

@Test func deepMergeConcatenatesShotsReindexesAndUnionsVisuals() throws {
    let p1 = Script(
        id: "a", videoSourceID: "v#seg0", title: "开场", summary: "摘要0",
        shots: [StoryboardShot(index: 0, startSeconds: 0, endSeconds: 3, narration: "n0", visualDescription: "d0", pacingNote: nil)],
        createdAt: Date(timeIntervalSince1970: 1),
        hookStructure: HookAnalysis(openingHook: "开场钩子", retentionDevices: ["悬念"], payoff: nil, callToAction: nil, whyItWorks: "有钩子"),
        visualElements: ["主角", "码头"]
    )
    let p2 = Script(
        id: "b", videoSourceID: "v#seg1", title: "第二段", summary: "摘要1",
        shots: [StoryboardShot(index: 0, startSeconds: 10, endSeconds: 13, narration: "n1", visualDescription: "d1", pacingNote: nil)],
        createdAt: Date(timeIntervalSince1970: 2),
        hookStructure: HookAnalysis(openingHook: "第二段的钩子", retentionDevices: [], payoff: nil, callToAction: nil, whyItWorks: "x"),
        visualElements: ["码头", "船"]
    )

    // Pass out of chronological order to prove the merge sorts by first-shot time.
    let merged = try #require(DeepScriptMerge.merge([p2, p1], sourceID: "v"))

    #expect(merged.videoSourceID == "v")
    #expect(merged.shots.map(\.index) == [0, 1])
    #expect(merged.shots.map(\.startSeconds) == [0, 10])
    #expect(merged.hookStructure?.openingHook == "开场钩子")  // opening segment's hook
    #expect(merged.visualElements == ["主角", "码头", "船"])   // union, deduped, order-preserved
    #expect(merged.title == "开场")                            // first-by-time non-empty
}

@Test func deepMergeReturnsNilForNoPartials() {
    #expect(DeepScriptMerge.merge([], sourceID: "v") == nil)
}

@Test func deepMergeComposesHookAcrossSegmentsAndJoinsSummaries() throws {
    // 爆点/CTA reveal late — a first-segment-only hook dropped them; summaries must cover the whole
    // video, not just the opening segment.
    let p1 = Script(
        id: "a", videoSourceID: "v#seg0", title: "开场", summary: "摘要0。",
        shots: [StoryboardShot(index: 0, startSeconds: 0, endSeconds: 3, narration: "n0", visualDescription: "d0", pacingNote: nil)],
        createdAt: Date(timeIntervalSince1970: 1),
        hookStructure: HookAnalysis(openingHook: "开场钩子", retentionDevices: ["悬念"], payoff: nil, callToAction: nil, whyItWorks: "有钩子"),
        visualElements: []
    )
    let p2 = Script(
        id: "b", videoSourceID: "v#seg1", title: "第二段", summary: "摘要1",
        shots: [StoryboardShot(index: 0, startSeconds: 10, endSeconds: 13, narration: "n1", visualDescription: "d1", pacingNote: nil)],
        createdAt: Date(timeIntervalSince1970: 2),
        hookStructure: HookAnalysis(openingHook: "第二段的钩子", retentionDevices: ["反转"], payoff: "后段爆点", callToAction: "关注我", whyItWorks: "x"),
        visualElements: []
    )

    let merged = try #require(DeepScriptMerge.merge([p2, p1], sourceID: "v"))

    #expect(merged.hookStructure?.openingHook == "开场钩子")          // opening from the first segment
    #expect(merged.hookStructure?.payoff == "后段爆点")               // 爆点 from the LAST segment that has one
    #expect(merged.hookStructure?.callToAction == "关注我")
    #expect(merged.hookStructure?.retentionDevices == ["悬念", "反转"]) // union across segments
    #expect(merged.summary == "摘要0。摘要1。")                        // whole-video summary, sentence-joined
}
