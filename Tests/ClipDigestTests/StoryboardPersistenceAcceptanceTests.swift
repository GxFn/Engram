import ClipCore
import ClipDigest
import ClipPipeline
import Foundation
import Persistence
import ScriptCore
import StoryboardCore
import Testing
import VideoUnderstanding

@Test func storyboardUndoReceiptAndLocksSurviveServiceReconstruction() async throws {
    let fixture = try StoryboardPersistenceFixture()
    let original = try persistenceStoryboardDocument()
    try await fixture.seed(document: original, quality: .clean)

    var firstService: ClipDigestService? = fixture.makeService()
    let applied = try await firstService?.applyStoryboardEdit(id: fixture.clipID) { document in
        try StoryboardEditor.editPlanField(
            document,
            shotID: ShotID(rawValue: "S001"),
            field: .dialogueOrVO,
            value: "persisted user dialogue",
            lock: true
        )
    }
    #expect(applied?.diff.changedFields == [.dialogueOrVO])
    firstService = nil

    // The lock is part of the durable V2 document, not an in-memory view-model override.
    let afterRestart = try await fixture.persistedDocument()
    #expect(afterRestart.shots[0].productionPlan?.dialogueOrVO == "persisted user dialogue")
    #expect(afterRestart.shots[0].userLockedFields.contains(EditablePlanField.dialogueOrVO.rawValue))

    // A fresh service must reconstruct the durable revision/receipt and be able to undo it.
    let reconstructedService = fixture.makeService()
    let undoReceipt = try await reconstructedService.undoStoryboard(id: fixture.clipID)

    #expect(undoReceipt.document == original)
    #expect(undoReceipt.diff.changedShotIDs == [ShotID(rawValue: "S001")])
    #expect(try await fixture.persistedDocument() == original)
}

@Test func failedPartialReanalysisPreservesLastGoodStoryboardAndQuality() async throws {
    let fixture = try StoryboardPersistenceFixture()
    let original = try persistenceStoryboardDocument()
    try await fixture.seed(document: original, quality: .clean)
    let originalSnapshot = try await fixture.records.snapshot(id: fixture.clipID)

    let service = fixture.makeService(videoAnalyzer: FactlessPartialReanalysisAnalyzer())
    let receipt = try? await service.reanalyzeStoryboard(id: fixture.clipID, shotIndex: 0)

    #expect(receipt == nil)
    let persisted = try await fixture.records.snapshot(id: fixture.clipID)
    #expect(persisted.storyboardJSON == originalSnapshot.storyboardJSON)
    #expect(persisted.scriptJSON == originalSnapshot.scriptJSON)
    #expect(persisted.qualityStatusRaw == QualityStatus.clean.rawValue)
    #expect(try await fixture.persistedDocument() == original)
}

private final class StoryboardPersistenceFixture {
    let clipID = "storyboard-persistence-acceptance"
    let rootURL: URL
    let queueStore: ClipQueueStore
    let records: ClipRecordStore
    let sourceURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EngramStoryboardPersistenceAcceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        queueStore = ClipQueueStore(queueDirectory: rootURL.appendingPathComponent("queue", isDirectory: true))
        records = ClipRecordStore(modelContainer: try PersistenceStack.makeContainer(inMemory: true))
        sourceURL = rootURL.appendingPathComponent("source.mp4")
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeService(videoAnalyzer: (any VideoAnalyzing)? = nil) -> ClipDigestService {
        ClipDigestService(
            queueStore: queueStore,
            recordStore: records,
            fetcher: PersistenceAcceptanceFetcher(),
            indexer: DigestPreviewIndexer(),
            videoAnalyzer: videoAnalyzer,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
    }

    func seed(document: StoryboardDocumentV2, quality: QualityStatus) async throws {
        let clip = Clip(
            id: clipID,
            source: .videoFile(sourceURL),
            title: "Storyboard persistence",
            note: nil,
            createdAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        _ = try await records.upsertQueuedClip(clip)
        _ = try await records.transition(id: clipID, to: .transcribing)
        _ = try await records.transition(id: clipID, to: .scripting)

        let legacy = StoryboardLegacyProjector.project(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let storyboardJSON = String(decoding: try encoder.encode(document), as: UTF8.self)
        _ = try await records.markIndexed(
            id: clipID,
            title: legacy.title,
            bodyText: ScriptRendering.indexableText(legacy),
            indexPreview: "seed",
            scriptJSON: try #require(ScriptCoding.encode(legacy)),
            storyboardJSON: storyboardJSON,
            activeRunID: document.source.runID,
            qualityStatusRaw: quality.rawValue,
            analysisSchemaVersion: document.source.schemaVersion
        )
    }

    func persistedDocument() async throws -> StoryboardDocumentV2 {
        let snapshot = try await records.snapshot(id: clipID)
        let json = try #require(snapshot.storyboardJSON)
        return try JSONDecoder().decode(StoryboardDocumentV2.self, from: Data(json.utf8))
    }
}

private struct PersistenceAcceptanceFetcher: ArticleFetching {
    func fetchHTML(from url: URL) async throws -> FetchedArticleHTML {
        throw URLError(.unsupportedURL)
    }
}

private enum PersistenceAcceptanceError: Error {
    case unusedFullAnalysis
}

private struct FactlessPartialReanalysisAnalyzer: EvidenceGroundedVideoAnalyzing {
    func analyzeGrounded(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> EvidenceGroundedAnalysis {
        throw PersistenceAcceptanceError.unusedFullAnalysis
    }

    func reanalyzeGrounded(
        _ source: VideoSource,
        document: StoryboardDocumentV2,
        shotIDs: [ShotID]
    ) async throws -> StoryboardDocumentV2 {
        let selected = Set(shotIDs)
        let shots = document.shots.map { shot in
            guard selected.contains(shot.id) else { return shot }
            return StoryboardShotV2(
                id: shot.id,
                observedFacts: ObservedShotFacts(
                    facts: [],
                    unknownFields: [.action, .audioSummary],
                    reviewFlags: ["shot-understanding-failed: injected"]
                ),
                productionPlan: shot.productionPlan,
                userLockedFields: shot.userLockedFields
            )
        }
        return StoryboardDocumentV2(
            id: document.id,
            source: document.source,
            shotGraph: document.shotGraph,
            shots: shots,
            contentAnalysis: document.contentAnalysis
        )
    }
}

private func persistenceStoryboardDocument() throws -> StoryboardDocumentV2 {
    let shotID = ShotID(rawValue: "S001")
    let asset = VideoAssetDescriptor(
        sourceID: "storyboard-persistence-acceptance",
        durationSeconds: 2,
        nominalFrameRate: 30,
        frameCount: 60,
        width: 720,
        height: 1280,
        timescale: 600,
        codec: "h264",
        hasAudio: true,
        fileSizeBytes: 100,
        fingerprint: SourceFingerprint(value: "persistence-fingerprint")
    )
    let graph = try ShotGraph(asset: asset, shots: [ShotSegment(
        id: shotID,
        timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 2),
        frameRange: FrameRange(startFrame: 0, endFrameExclusive: 60),
        transitionIn: .start,
        transitionOut: .end,
        boundaryConfidence: 0.95,
        detectorEvidenceIDs: ["detector:S001"],
        representativeFrameRefs: ["shots/S001/representative-1.jpg"]
    )])
    return StoryboardDocumentV2(
        id: "storyboard-persistence-document",
        source: StoryboardSource(
            sourceID: asset.sourceID,
            runID: "run-persistence",
            schemaVersion: 2,
            pipelineVersion: "storyboard-v2.1",
            mode: .faithful,
            actualCloudMode: .local,
            mediaUploaded: false
        ),
        shotGraph: graph,
        shots: [StoryboardShotV2(
            id: shotID,
            observedFacts: ObservedShotFacts(facts: [GroundedFact(
                field: .action,
                value: "presenter turns",
                evidenceIDs: [EvidenceID(rawValue: "frame:S001:1")],
                source: .onDeviceModel,
                confidence: 0.9
            )]),
            productionPlan: ShotProductionPlan(
                shotID: shotID,
                displayNumber: 1,
                subjectAction: "presenter turns",
                dialogueOrVO: "original dialogue",
                sourceShotRefs: [shotID],
                isDerivedCreativePlan: true
            )
        )],
        contentAnalysis: ContentAnalysis(summary: "Persistence acceptance fixture", referencedShotIDs: [shotID])
    )
}
