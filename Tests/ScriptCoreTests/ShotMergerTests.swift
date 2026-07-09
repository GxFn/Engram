import Foundation
import Testing
@testable import ScriptCore

@Test func shotMergerFoldsSubMinimumFragmentIntoNeighbor() {
    // A noisy ASR split ("我" as its own 0.1s shot) must not survive as a 分镜.
    let shots = [
        StoryboardShot(index: 0, startSeconds: 0, endSeconds: 2.7, narration: "不用说了", visualDescription: "近景A"),
        StoryboardShot(index: 1, startSeconds: 2.7, endSeconds: 2.8, narration: "我", visualDescription: ""),
        StoryboardShot(index: 2, startSeconds: 2.8, endSeconds: 5.8, narration: "也不会再留在京东了", visualDescription: "近景B"),
    ]

    let merged = ShotMerger.merge(shots, minSeconds: 1.2)

    #expect(merged.count == 2)
    #expect(merged.map(\.index) == [0, 1])
    #expect(merged.allSatisfy { $0.endSeconds - $0.startSeconds >= 1.2 })
    #expect(merged[0].narration == "不用说了 我")
    #expect(merged[0].startSeconds == 0)
    #expect(merged[0].endSeconds == 2.8)
    #expect(merged[0].visualDescription == "近景A") // fragment's empty visual doesn't overwrite
}

@Test func shotMergerUnionsOnScreenTextWhenFolding() {
    let shots = [
        StoryboardShot(index: 0, startSeconds: 0, endSeconds: 2, narration: "a", visualDescription: "x", onScreenText: ["字幕1"]),
        StoryboardShot(index: 1, startSeconds: 2, endSeconds: 2.3, narration: "b", visualDescription: "", onScreenText: ["字幕2"]),
    ]

    let merged = ShotMerger.merge(shots, minSeconds: 1.0)

    #expect(merged.count == 1)
    #expect(merged[0].onScreenText == ["字幕1", "字幕2"])
}

@Test func shotMergerKeepsAdequateShotsUntouched() {
    let shots = [
        StoryboardShot(index: 0, startSeconds: 0, endSeconds: 2, narration: "a", visualDescription: "x"),
        StoryboardShot(index: 1, startSeconds: 2, endSeconds: 4, narration: "b", visualDescription: "y"),
    ]

    let merged = ShotMerger.merge(shots, minSeconds: 1.2)

    #expect(merged.count == 2)
    #expect(merged.map(\.narration) == ["a", "b"])
}

@Test func shotMergerLeavesASingleShotAlone() {
    let shots = [StoryboardShot(index: 0, startSeconds: 0, endSeconds: 0.5, narration: "x", visualDescription: "y")]
    #expect(ShotMerger.merge(shots, minSeconds: 1.2).count == 1)
}

@Test func shotMergerDoesNotCascadeFastShortSentences() {
    // Regression: four legitimate ~0.6s sentences (fast-paced 爆款) must each stay their own 分镜,
    // not cascade-collapse into one. (The old `duration(previous) < min || duration(shot) < min`
    // rule folded every short shot into the previous, swallowing whole runs.)
    let shots = (0..<4).map { i in
        StoryboardShot(index: i, startSeconds: Double(i) * 0.6, endSeconds: Double(i) * 0.6 + 0.6,
                       narration: "句\(i)", visualDescription: "画\(i)")
    }
    let merged = ShotMerger.merge(shots) // default minSeconds 0.35 < 0.6
    #expect(merged.count == 4)
    #expect(merged.map(\.narration) == ["句0", "句1", "句2", "句3"])
}

@Test func shotMergerDoesNotFuseFragmentAcrossAGap() {
    // Regression: a tiny fragment far down the timeline must not fuse into a distant earlier shot
    // (the old merge took min(start)/max(end) with no adjacency check → one 0–50.2s mashed shot).
    let shots = [
        StoryboardShot(index: 0, startSeconds: 0, endSeconds: 2, narration: "开头", visualDescription: "x"),
        StoryboardShot(index: 1, startSeconds: 50, endSeconds: 50.2, narration: "碎", visualDescription: ""),
    ]
    let merged = ShotMerger.merge(shots, minSeconds: 0.35)
    #expect(merged.count == 2)
    #expect(merged[1].startSeconds == 50)
}
