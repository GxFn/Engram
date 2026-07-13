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
