import Testing
@testable import VideoUnderstanding

@Test func fixtureLabelsRejectPlaceholdersAndTimelineGaps() throws {
    let valid = StoryboardFixtureLabel(
        fixtureID: "synthetic-hard-cut",
        sha256: String(repeating: "a", count: 64),
        durationSeconds: 2,
        frameRate: 30,
        frameCount: 60,
        shots: [
            BoundaryLabel(startFrame: 0, endFrameExclusive: 30, transitionOut: .cut),
            BoundaryLabel(startFrame: 30, endFrameExclusive: 60, transitionOut: .end),
        ]
    )
    try valid.validate()

    let placeholder = StoryboardFixtureLabel(
        fixtureID: "1358",
        sha256: String(repeating: "b", count: 64),
        durationSeconds: 12.833984,
        frameRate: 30,
        frameCount: 385,
        shots: [BoundaryLabel(startFrame: 0, endFrameExclusive: 0, transitionOut: .cut)]
    )
    #expect(throws: FixtureLabelValidationError.self) {
        try placeholder.validate()
    }

    let gap = StoryboardFixtureLabel(
        fixtureID: "gapped",
        sha256: String(repeating: "c", count: 64),
        durationSeconds: 2,
        frameRate: 30,
        frameCount: 60,
        shots: [
            BoundaryLabel(startFrame: 0, endFrameExclusive: 29, transitionOut: .cut),
            BoundaryLabel(startFrame: 30, endFrameExclusive: 60, transitionOut: .end),
        ]
    )
    #expect(throws: FixtureLabelValidationError.self) {
        try gap.validate()
    }
}

@Test func boundaryEvaluationIsDeterministicAndKeepsTransitionBucketsSeparate() throws {
    let labels = [
        BoundaryLabel(startFrame: 0, endFrameExclusive: 30, transitionOut: .cut),
        BoundaryLabel(startFrame: 30, endFrameExclusive: 60, transitionOut: .fade),
        BoundaryLabel(startFrame: 60, endFrameExclusive: 90, transitionOut: .end),
    ]
    let predictions = [
        BoundaryPrediction(frame: 29, transition: .cut, confidence: 0.95),
        BoundaryPrediction(frame: 61, transition: .fade, confidence: 0.85),
        BoundaryPrediction(frame: 75, transition: .cut, confidence: 0.7),
    ]

    let first = BoundaryEvaluator.evaluate(labels: labels, predictions: predictions, toleranceFrames: 2)
    let second = BoundaryEvaluator.evaluate(labels: labels, predictions: predictions, toleranceFrames: 2)

    #expect(first == second)
    #expect(first.hard.truePositive == 1)
    #expect(first.hard.falsePositive == 1)
    #expect(first.hard.falseNegative == 0)
    #expect(abs(first.hard.f1 - (2.0 / 3.0)) < 0.000_001)
    #expect(first.gradual.f1 == 1)
    #expect(abs(first.overall.f1 - 0.8) < 0.000_001)
    #expect(first.matches.map(\.predictionFrame) == [29, 61])
}
