import StoryboardCore
import Testing
import VideoUnderstanding

@Test func storyboardValidatorRejectsMachineFactsWithoutEvidenceLinks() throws {
    let graph = try storyboardFixtureGraph()
    let unsupported = GroundedFact(
        field: .action,
        value: "人物快速转身",
        evidenceIDs: [],
        source: .cloudModel,
        confidence: 0.92
    )
    let document = StoryboardDocumentV2(
        id: "doc-1",
        source: StoryboardSource(
            sourceID: "fixture",
            runID: "run-1",
            schemaVersion: 2,
            pipelineVersion: "storyboard-v2",
            mode: .faithful,
            actualCloudMode: .local,
            mediaUploaded: false
        ),
        shotGraph: graph,
        shots: [
            StoryboardShotV2(
                id: graph.shots[0].id,
                observedFacts: ObservedShotFacts(facts: [unsupported]),
                productionPlan: ShotProductionPlan(
                    shotID: graph.shots[0].id,
                    displayNumber: 1,
                    sourceShotRefs: [graph.shots[0].id],
                    isDerivedCreativePlan: true
                )
            )
        ],
        contentAnalysis: ContentAnalysis(summary: "开场", referencedShotIDs: [graph.shots[0].id])
    )

    let report = StoryboardValidator.validate(document: document, evidence: [])

    #expect(report.status == .needsReview)
    #expect(report.issues.map(\.code).contains("unsupported-machine-fact"))
    #expect(report.machineFactCount == 1)
    #expect(report.groundedMachineFactCount == 0)
}

private func storyboardFixtureGraph() throws -> ShotGraph {
    let asset = VideoAssetDescriptor(
        sourceID: "fixture",
        durationSeconds: 1,
        nominalFrameRate: 30,
        frameCount: 30,
        width: 720,
        height: 1280,
        timescale: 600,
        codec: "h264",
        hasAudio: true,
        fileSizeBytes: 100,
        fingerprint: SourceFingerprint(value: "fingerprint")
    )
    return try ShotGraph(asset: asset, shots: [
        ShotSegment(
            id: ShotID(rawValue: "S001"),
            timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 1),
            frameRange: FrameRange(startFrame: 0, endFrameExclusive: 30),
            transitionIn: .start,
            transitionOut: .end,
            boundaryConfidence: 1,
            detectorEvidenceIDs: ["detector:S001"]
        )
    ])
}
