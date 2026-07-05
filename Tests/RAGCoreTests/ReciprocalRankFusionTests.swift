import Testing
@testable import RAGCore

@Test func documentInBothRankingsWinsFusion() {
    let dense = ["a", "b", "c"]
    let sparse = ["b", "d"]
    let fused = ReciprocalRankFusion.fuse(rankings: [dense, sparse])
    #expect(fused.first == "b") // only "b" appears in both lists
    #expect(Set(fused) == Set(["a", "b", "c", "d"]))
}

@Test func equalScoresBreakTiesDeterministically() {
    // "x" and "y" each rank first in exactly one list → identical RRF scores;
    // ordering must still be stable so eval runs stay reproducible.
    let fused = ReciprocalRankFusion.fuse(rankings: [["x"], ["y"]])
    #expect(fused == ["x", "y"])
}

@Test func emptyRankingsProduceEmptyFusion() {
    let fused = ReciprocalRankFusion.fuse(rankings: [[String]]())
    #expect(fused.isEmpty)
}
