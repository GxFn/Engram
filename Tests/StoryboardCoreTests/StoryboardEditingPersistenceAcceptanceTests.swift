import StoryboardCore
import Testing
import VideoUnderstanding

@Test func boundaryEditPreservesRepresentativeFrameReferences() throws {
    let document = try representativeFrameDocument()
    let firstID = document.shotGraph.shots[0].id

    let edited = try StoryboardEditor.moveBoundary(document, after: firstID, toSeconds: 1.25)

    #expect(edited.document.shotGraph.shots[0].representativeFrameRefs == [
        "shots/S001/representative-1.jpg",
        "shots/S001/representative-2.jpg",
    ])
    #expect(edited.document.shotGraph.shots[1].representativeFrameRefs == [
        "shots/S002/representative-1.jpg",
    ])
}

private func representativeFrameDocument() throws -> StoryboardDocumentV2 {
    let asset = VideoAssetDescriptor(
        sourceID: "representative-frame-edit",
        durationSeconds: 2,
        nominalFrameRate: 30,
        frameCount: 60,
        width: 720,
        height: 1280,
        timescale: 600,
        codec: "h264",
        hasAudio: true,
        fileSizeBytes: 100,
        fingerprint: SourceFingerprint(value: "representative-frame-fingerprint")
    )
    let graph = try ShotGraph(asset: asset, shots: [
        ShotSegment(
            id: ShotID(rawValue: "S001"),
            timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 1),
            frameRange: FrameRange(startFrame: 0, endFrameExclusive: 30),
            transitionIn: .start,
            transitionOut: .cut,
            boundaryConfidence: 0.9,
            detectorEvidenceIDs: ["detector:S001"],
            representativeFrameRefs: [
                "shots/S001/representative-1.jpg",
                "shots/S001/representative-2.jpg",
            ]
        ),
        ShotSegment(
            id: ShotID(rawValue: "S002"),
            timeRange: MediaTimeRange(startSeconds: 1, endSeconds: 2),
            frameRange: FrameRange(startFrame: 30, endFrameExclusive: 60),
            transitionIn: .cut,
            transitionOut: .end,
            boundaryConfidence: 0.9,
            detectorEvidenceIDs: ["detector:S002"],
            representativeFrameRefs: ["shots/S002/representative-1.jpg"]
        ),
    ])
    return StoryboardDocumentV2(
        id: "representative-frame-document",
        source: StoryboardSource(
            sourceID: asset.sourceID,
            runID: "representative-frame-run",
            schemaVersion: 2,
            pipelineVersion: "storyboard-v2.1",
            mode: .faithful,
            actualCloudMode: .local,
            mediaUploaded: false
        ),
        shotGraph: graph,
        shots: graph.shots.enumerated().map { index, segment in
            StoryboardShotV2(
                id: segment.id,
                observedFacts: ObservedShotFacts(facts: []),
                productionPlan: ShotProductionPlan(
                    shotID: segment.id,
                    displayNumber: index + 1,
                    sourceShotRefs: [segment.id],
                    isDerivedCreativePlan: true
                )
            )
        },
        contentAnalysis: ContentAnalysis(
            summary: "Representative frame edit fixture",
            referencedShotIDs: graph.shots.map(\.id)
        )
    )
}
