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
