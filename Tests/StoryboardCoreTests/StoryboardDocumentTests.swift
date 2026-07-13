import Foundation
import StoryboardCore
import ScriptCore
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

@Test func legacyProjectionIsDeterministicAndKeepsAuthoritativeShotBounds() throws {
    let graph = try storyboardFixtureGraph()
    let plan = ShotProductionPlan(
        shotID: graph.shots[0].id,
        displayNumber: 1,
        purpose: "建立冲突",
        subjectAction: "人物转身",
        dialogueOrVO: "不要离开",
        onScreenCopy: "留下",
        sourceShotRefs: [graph.shots[0].id],
        isDerivedCreativePlan: true
    )
    let document = StoryboardDocumentV2(
        id: "doc-projection",
        source: StoryboardSource(
            sourceID: "fixture", runID: "run-projection", schemaVersion: 2,
            pipelineVersion: "storyboard-v2", mode: .faithful,
            actualCloudMode: .local, mediaUploaded: false
        ),
        shotGraph: graph,
        shots: [StoryboardShotV2(
            id: graph.shots[0].id,
            observedFacts: ObservedShotFacts(facts: []),
            productionPlan: plan
        )],
        contentAnalysis: ContentAnalysis(
            title: "测试分镜", summary: "确定性旧版投影", hook: "开场冲突",
            referencedShotIDs: [graph.shots[0].id]
        )
    )

    let first = StoryboardLegacyProjector.project(document, createdAt: Date(timeIntervalSince1970: 1))
    let second = StoryboardLegacyProjector.project(document, createdAt: Date(timeIntervalSince1970: 1))

    #expect(first == second)
    #expect(first.videoSourceID == "fixture")
    #expect(first.shots[0].startSeconds == 0)
    #expect(first.shots[0].endSeconds == 1)
    #expect(first.shots[0].narration == "不要离开")
    #expect(first.shots[0].visualDescription.contains("人物转身"))
    #expect(first.shots[0].onScreenText == ["留下"])
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
