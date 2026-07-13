import Foundation
import StoryboardCore
import StoryboardExport
import Testing
import VideoUnderstanding

@Test func exporterWritesAndValidatesFiveRealFormats() throws {
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramStoryboardExportTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: output) }
    let document = try exportDocument()
    let keyframe = ShotKeyframe(
        shotID: document.shots[0].id,
        frame: SampledFrame(timestampSeconds: 0.5, jpegData: Data([0xff, 0xd8, 0xff, 0xd9])),
        artifactRef: "shots/S001/representative.jpg"
    )

    let bundle = try StoryboardExporter().export(document, keyframes: [keyframe], to: output)
    let report = StoryboardExportValidator.validate(bundle, document: document)

    #expect(bundle.artifacts.count == 5)
    #expect(Set(bundle.artifacts.map(\.format)) == Set(StoryboardExportFormat.allCases))
    #expect(report.isValid)
    #expect(report.issues.isEmpty)
}

private func exportDocument() throws -> StoryboardDocumentV2 {
    let asset = VideoAssetDescriptor(
        sourceID: "export", durationSeconds: 1, nominalFrameRate: 30, frameCount: 30,
        width: 720, height: 1280, timescale: 600, codec: "h264", hasAudio: false,
        fileSizeBytes: 4, fingerprint: SourceFingerprint(value: "export")
    )
    let id = ShotID(rawValue: "S001")
    let graph = try ShotGraph(asset: asset, shots: [ShotSegment(
        id: id, timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 1),
        frameRange: FrameRange(startFrame: 0, endFrameExclusive: 30),
        transitionIn: .start, transitionOut: .end, boundaryConfidence: 1,
        detectorEvidenceIDs: ["detector:S001"]
    )])
    return StoryboardDocumentV2(
        id: "export-document",
        source: StoryboardSource(
            sourceID: "export", runID: "run-export", schemaVersion: 2,
            pipelineVersion: "v2", mode: .faithful, actualCloudMode: .local,
            mediaUploaded: false
        ),
        shotGraph: graph,
        shots: [StoryboardShotV2(
            id: id, observedFacts: ObservedShotFacts(facts: []),
            productionPlan: ShotProductionPlan(
                shotID: id, displayNumber: 1, purpose: "开场",
                subjectAction: "人物出现", sourceShotRefs: [id], isDerivedCreativePlan: true
            )
        )],
        contentAnalysis: ContentAnalysis(title: "导出测试", summary: "五类导出", referencedShotIDs: [id])
    )
}
