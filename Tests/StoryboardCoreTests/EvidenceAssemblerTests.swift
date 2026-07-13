import StoryboardCore
import Testing
import VideoUnderstanding

@Test func evidenceAssemblerSharesCrossBoundaryEvidenceByActualOverlap() throws {
    let graph = try fixtureGraph()
    let evidence = EvidenceRef(
        id: EvidenceID(rawValue: "asr-1"),
        kind: .transcript,
        timeRange: MediaTimeRange(startSeconds: 0.8, endSeconds: 1.2),
        frameRange: nil,
        payloadRef: "transcript/asr-1.json",
        source: .onDeviceModel,
        confidence: 0.9,
        modelVersion: "speech-v1",
        rawText: "raw line",
        correctedText: "corrected line"
    )

    let result = ShotEvidenceAssembler.assemble(graph: graph, evidence: [evidence])

    #expect(result.shots.count == 2)
    #expect(result.shots[0].evidenceIDs == [evidence.id])
    #expect(result.shots[1].evidenceIDs == [evidence.id])
    #expect(result.coverage.orphanEvidenceIDs.isEmpty)
    #expect(result.coverage.sharedEvidenceIDs == [evidence.id])
    #expect(evidence.rawText == "raw line")
    #expect(evidence.correctedText == "corrected line")
}

private func fixtureGraph() throws -> ShotGraph {
    let asset = VideoAssetDescriptor(
        sourceID: "fixture",
        durationSeconds: 2,
        nominalFrameRate: 30,
        frameCount: 60,
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
            transitionOut: .cut,
            boundaryConfidence: 1,
            detectorEvidenceIDs: ["detector:S001"]
        ),
        ShotSegment(
            id: ShotID(rawValue: "S002"),
            timeRange: MediaTimeRange(startSeconds: 1, endSeconds: 2),
            frameRange: FrameRange(startFrame: 30, endFrameExclusive: 60),
            transitionIn: .cut,
            transitionOut: .end,
            boundaryConfidence: 1,
            detectorEvidenceIDs: ["detector:S002"]
        ),
    ])
}
