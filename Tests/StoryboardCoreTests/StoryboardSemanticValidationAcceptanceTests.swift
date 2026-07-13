import StoryboardCore
import Testing
import VideoUnderstanding

@Test func semanticValidatorRejectsFactLinkedToWrongEvidenceKind() throws {
    let fixture = try semanticFixture()
    let fact = GroundedFact(
        field: .action,
        value: "person turns",
        evidenceIDs: [EvidenceID(rawValue: "transcript:S001")],
        source: .onDeviceModel,
        confidence: 0.9
    )
    let evidence = EvidenceRef(
        id: EvidenceID(rawValue: "transcript:S001"),
        kind: .transcript,
        timeRange: fixture.graph.shots[0].timeRange,
        frameRange: nil,
        payloadRef: "transcript/S001.json",
        source: .deterministic,
        confidence: 0.9,
        rawText: "person turns"
    )

    let report = StoryboardValidator.validate(
        document: semanticDocument(graph: fixture.graph, facts: [fact]),
        evidence: [evidence]
    )

    #expect(report.status != .clean)
    #expect(report.issues.map(\.code).contains("evidence-kind-mismatch"))
}

@Test func semanticValidatorRejectsEvidenceOutsideOwningShot() throws {
    let fixture = try semanticFixture()
    let fact = GroundedFact(
        field: .action,
        value: "person turns",
        evidenceIDs: [EvidenceID(rawValue: "frame:S002")],
        source: .onDeviceModel,
        confidence: 0.9
    )
    let evidence = EvidenceRef(
        id: EvidenceID(rawValue: "frame:S002"),
        kind: .frame,
        timeRange: fixture.graph.shots[1].timeRange,
        frameRange: fixture.graph.shots[1].frameRange,
        payloadRef: "shots/S002/representative-1.jpg",
        source: .deterministic,
        confidence: 1
    )

    let report = StoryboardValidator.validate(
        document: semanticDocument(graph: fixture.graph, facts: [fact]),
        evidence: [evidence]
    )

    #expect(report.status != .clean)
    #expect(report.issues.map(\.code).contains("evidence-outside-shot"))
}

@Test func semanticValidatorRejectsVisibleTextThatDoesNotMatchOCREvidence() throws {
    let fixture = try semanticFixture()
    let fact = GroundedFact(
        field: .visibleText,
        value: "ENTER",
        evidenceIDs: [EvidenceID(rawValue: "ocr:S001")],
        source: .onDeviceModel,
        confidence: 0.9
    )
    let evidence = EvidenceRef(
        id: EvidenceID(rawValue: "ocr:S001"),
        kind: .ocr,
        timeRange: MediaTimeRange(startSeconds: 0.4, endSeconds: 0.41),
        frameRange: FrameRange(startFrame: 12, endFrameExclusive: 13),
        payloadRef: "ocr/S001.json",
        source: .deterministic,
        confidence: 0.9,
        rawText: "EXIT"
    )

    let report = StoryboardValidator.validate(
        document: semanticDocument(graph: fixture.graph, facts: [fact]),
        evidence: [evidence]
    )

    #expect(report.status != .clean)
    #expect(report.issues.map(\.code).contains("evidence-text-mismatch"))
}

@Test func semanticValidatorRejectsAudioSummaryThatDoesNotMatchTranscriptEvidence() throws {
    let fixture = try semanticFixture()
    let fact = GroundedFact(
        field: .audioSummary,
        value: "goodbye",
        evidenceIDs: [EvidenceID(rawValue: "transcript:S001")],
        source: .onDeviceModel,
        confidence: 0.9
    )
    let evidence = EvidenceRef(
        id: EvidenceID(rawValue: "transcript:S001"),
        kind: .transcript,
        timeRange: MediaTimeRange(startSeconds: 0.1, endSeconds: 0.8),
        frameRange: nil,
        payloadRef: "transcript/S001.json",
        source: .deterministic,
        confidence: 0.9,
        rawText: "hello"
    )

    let report = StoryboardValidator.validate(
        document: semanticDocument(graph: fixture.graph, facts: [fact]),
        evidence: [evidence]
    )

    #expect(report.status != .clean)
    #expect(report.issues.map(\.code).contains("evidence-text-mismatch"))
}

@Test func semanticValidatorRejectsFactlessFailedShotAsClean() throws {
    let fixture = try semanticFixture()
    let document = semanticDocument(
        graph: fixture.graph,
        facts: [],
        firstShotReviewFlags: ["shot-understanding-failed: injected"]
    )

    let report = StoryboardValidator.validate(document: document, evidence: [])

    #expect(report.status != .clean)
    #expect(report.issues.map(\.code).contains("factless-failed-shot"))
}

private struct SemanticFixture {
    let graph: ShotGraph
}

private func semanticFixture() throws -> SemanticFixture {
    let asset = VideoAssetDescriptor(
        sourceID: "semantic-acceptance",
        durationSeconds: 2,
        nominalFrameRate: 30,
        frameCount: 60,
        width: 720,
        height: 1280,
        timescale: 600,
        codec: "h264",
        hasAudio: true,
        fileSizeBytes: 100,
        fingerprint: SourceFingerprint(value: "semantic-fingerprint")
    )
    return SemanticFixture(graph: try ShotGraph(asset: asset, shots: [
        ShotSegment(
            id: ShotID(rawValue: "S001"),
            timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 1),
            frameRange: FrameRange(startFrame: 0, endFrameExclusive: 30),
            transitionIn: .start,
            transitionOut: .cut,
            boundaryConfidence: 0.9,
            detectorEvidenceIDs: ["detector:S001"]
        ),
        ShotSegment(
            id: ShotID(rawValue: "S002"),
            timeRange: MediaTimeRange(startSeconds: 1, endSeconds: 2),
            frameRange: FrameRange(startFrame: 30, endFrameExclusive: 60),
            transitionIn: .cut,
            transitionOut: .end,
            boundaryConfidence: 0.9,
            detectorEvidenceIDs: ["detector:S002"]
        ),
    ]))
}

private func semanticDocument(
    graph: ShotGraph,
    facts: [GroundedFact],
    firstShotReviewFlags: [String] = []
) -> StoryboardDocumentV2 {
    StoryboardDocumentV2(
        id: "semantic-document",
        source: StoryboardSource(
            sourceID: graph.asset.sourceID,
            runID: "semantic-run",
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
                observedFacts: ObservedShotFacts(
                    facts: index == 0 ? facts : [],
                    unknownFields: index == 0 && facts.isEmpty ? [.action] : [],
                    reviewFlags: index == 0 ? firstShotReviewFlags : []
                ),
                productionPlan: ShotProductionPlan(
                    shotID: segment.id,
                    displayNumber: index + 1,
                    sourceShotRefs: [segment.id],
                    isDerivedCreativePlan: true
                )
            )
        },
        contentAnalysis: ContentAnalysis(
            summary: "Semantic validation acceptance fixture",
            referencedShotIDs: graph.shots.map(\.id)
        )
    )
}
