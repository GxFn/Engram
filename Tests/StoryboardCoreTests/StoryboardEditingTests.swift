import StoryboardCore
import Testing
import VideoUnderstanding

@Test func splitProducesRemapDiffUndoAndScopedRerun() throws {
    let original = try editableDocument()

    let result = try StoryboardEditor.split(original, shotID: ShotID(rawValue: "S001"), atSeconds: 1)

    #expect(result.document.shotGraph.shots.count == 2)
    #expect(result.remap.targets(for: ShotID(rawValue: "S001")).count == 2)
    #expect(result.diff.changedShotIDs.count == 2)
    #expect(result.undo() == original)
    #expect(result.partialRerun.invalidatedStages == [.synthesis, .quality, .indexing])
    #expect(result.document.shotGraph.coverageRatio == 1)
}

@Test func lockedPlanFieldSurvivesModelRefresh() throws {
    let original = try editableDocument()
    let edited = try StoryboardEditor.editPlanField(
        original, shotID: ShotID(rawValue: "S001"), field: .dialogueOrVO,
        value: "用户锁定台词", lock: true
    )
    let refreshed = try StoryboardEditor.applyModelRefresh(
        edited.document,
        shotID: ShotID(rawValue: "S001"),
        values: [.dialogueOrVO: "模型新台词", .subjectAction: "模型新动作"]
    )

    #expect(refreshed.document.shots[0].productionPlan?.dialogueOrVO == "用户锁定台词")
    #expect(refreshed.document.shots[0].productionPlan?.subjectAction == "模型新动作")
    #expect(refreshed.diff.preservedLockedFields == [.dialogueOrVO])
}

private func editableDocument() throws -> StoryboardDocumentV2 {
    let asset = VideoAssetDescriptor(
        sourceID: "editable", durationSeconds: 2, nominalFrameRate: 30, frameCount: 60,
        width: 720, height: 1280, timescale: 600, codec: "h264", hasAudio: true,
        fileSizeBytes: 10, fingerprint: SourceFingerprint(value: "editable")
    )
    let graph = try ShotGraph(asset: asset, shots: [ShotSegment(
        id: ShotID(rawValue: "S001"),
        timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 2),
        frameRange: FrameRange(startFrame: 0, endFrameExclusive: 60),
        transitionIn: .start, transitionOut: .end, boundaryConfidence: 0.9,
        detectorEvidenceIDs: ["detector:S001"]
    )])
    return StoryboardDocumentV2(
        id: "editable-document",
        source: StoryboardSource(
            sourceID: "editable", runID: "run-editable", schemaVersion: 2,
            pipelineVersion: "v2", mode: .faithful, actualCloudMode: .local,
            mediaUploaded: false
        ),
        shotGraph: graph,
        shots: [StoryboardShotV2(
            id: ShotID(rawValue: "S001"), observedFacts: ObservedShotFacts(facts: []),
            productionPlan: ShotProductionPlan(
                shotID: ShotID(rawValue: "S001"), displayNumber: 1,
                subjectAction: "原动作", dialogueOrVO: "原台词",
                sourceShotRefs: [ShotID(rawValue: "S001")], isDerivedCreativePlan: true
            )
        )],
        contentAnalysis: ContentAnalysis(summary: "可编辑", referencedShotIDs: [ShotID(rawValue: "S001")])
    )
}
