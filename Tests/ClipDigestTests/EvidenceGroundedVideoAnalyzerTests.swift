import AnalysisStore
import ClipCore
import ClipDigest
import Foundation
import ScriptCore
import StoryboardCore
import Testing
import VideoUnderstanding

@Test func groundedAnalyzerConnectsV2ToLegacyAndCheckpointStore() async throws {
    let retainedPath = ProcessInfo.processInfo.environment["ENGRAM_ARTIFACT_EVIDENCE_DIR"]
    let root = retainedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("EngramGroundedAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        if retainedPath == nil { try? FileManager.default.removeItem(at: root) }
    }
    try? FileManager.default.removeItem(at: root)
    let store = try AnalysisArtifactStore(rootURL: root, now: { Date(timeIntervalSince1970: 10) })
    let source = VideoSource(
        id: "clip-grounded",
        localFileURL: URL(fileURLWithPath: "/tmp/fixture.mp4"),
        importedAt: Date(timeIntervalSince1970: 1)
    )
    let asset = groundedAsset(sourceID: source.id)
    let graph = try groundedGraph(asset: asset)
    let calls = GroundedCallLedger()
    let analyzer = EvidenceGroundedVideoAnalyzer(
        probe: GroundedProbe(asset: asset, calls: calls),
        detector: GroundedDetector(graph: graph, calls: calls),
        keyframeSelector: GroundedKeyframes(shotID: graph.shots[0].id, calls: calls),
        transcriber: GroundedTranscriber(calls: calls),
        corrector: GroundedCorrector(),
        recognizer: GroundedOCR(calls: calls),
        understandingProvider: GroundedUnderstanding(calls: calls),
        cloudEnricher: GroundedCloud(calls: calls),
        artifactStore: store,
        pipelineVersion: "test-v2",
        runID: { "run-grounded" }
    )

    let result = try await analyzer.analyzeGrounded(source, onStage: { _ in })
    let resumedResult = try await analyzer.analyzeGrounded(source, onStage: { _ in })
    let resumed = try await store.loadResumableRun(
        clipID: source.id,
        fingerprint: asset.fingerprint,
        pipelineVersion: "test-v2"
    )

    #expect(result.document.source.runID == "run-grounded")
    #expect(result.document.shotGraph.shots.map(\.id) == graph.shots.map(\.id))
    #expect(result.document.shotGraph.shots.allSatisfy { $0.representativeFrameRefs.count == 1 })
    #expect(result.legacy.shots[0].startSeconds == graph.shots[0].timeRange.startSeconds)
    #expect(result.quality.evidenceLinkCoverage == 1)
    #expect(result.evidence.contains { $0.kind == EvidenceKind.frame })
    #expect(result.evidence.contains { $0.kind == EvidenceKind.transcript && $0.rawText == "原始台词" && $0.correctedText == "校正台词" })
    #expect(result.evidence.contains { $0.kind == EvidenceKind.ocr && $0.timeRange.startSeconds == 0.4 })
    #expect(result.evidence.contains { $0.kind == EvidenceKind.cloudTimeline })
    #expect(result.run.status == .completed)
    #expect(result.run.completedStages == AnalysisStage.allCases)
    #expect(resumed?.status == .completed)
    #expect(resumed?.completedStages == AnalysisStage.allCases)
    #expect(resumedResult.run.id == result.run.id)
    #expect(await calls.value("probe") == 2)
    #expect(await calls.value("detector") == 1)
    #expect(await calls.value("keyframes") == 2)
    #expect(await calls.value("transcriber") == 1)
    #expect(await calls.value("ocr") == 1)
    #expect(await calls.value("understanding") == 3)
    #expect(await calls.value("cloud") == 1)
    #expect(result.run.cloudTelemetry?.requestedMode == EffectiveCloudMode.cloudDeep.rawValue)
    #expect(result.run.cloudTelemetry?.effectiveMode == EffectiveCloudMode.cloudDeep.rawValue)
    #expect(result.run.cloudTelemetry?.mediaBytesUploaded == 3)
    #expect(result.run.cloudTelemetry?.refinementShotIDs == [graph.shots[0].id.rawValue])
    #expect(resumed?.cloudTelemetry == result.run.cloudTelemetry)
    let partiallyRefreshed = try await analyzer.reanalyzeGrounded(
        source,
        document: result.document,
        shotIDs: [graph.shots[0].id]
    )
    #expect(partiallyRefreshed.shots.count == 2)
    #expect(await calls.value("understanding") == 4)
}

private struct GroundedTranscriber: Transcriber {
    let calls: GroundedCallLedger
    func transcribe(_ source: VideoSource) async throws -> [TranscriptSegment] {
        await calls.increment("transcriber")
        return [TranscriptSegment(startSeconds: 0.1, endSeconds: 0.8, text: "原始台词")]
    }
}

private struct GroundedCorrector: TranscriptCorrecting {
    func correct(_ segments: [TranscriptSegment], onScreenText: [FrameText]) async throws -> [TranscriptSegment] {
        [TranscriptSegment(startSeconds: segments[0].startSeconds, endSeconds: segments[0].endSeconds, text: "校正台词")]
    }
}

private struct GroundedOCR: FrameTextRecognizing {
    let calls: GroundedCallLedger
    func recognizeText(in source: VideoSource) async -> [FrameText] {
        await calls.increment("ocr")
        return [FrameText(timestampSeconds: 0.4, lines: ["画面文字"])]
    }
}

private struct GroundedUnderstanding: ShotUnderstandingProviding {
    let calls: GroundedCallLedger
    func understand(_ input: ShotUnderstandingInput, displayNumber: Int) async throws -> ShotUnderstandingOutput {
        await calls.increment("understanding")
        let evidenceIDs = input.evidence
            .filter { $0.kind == .frame || $0.kind == .ocr || $0.kind == .cloudTimeline }
            .map(\.id)
        return ShotUnderstandingOutput(
            shot: StoryboardShotV2(
                id: input.shot.id,
                observedFacts: ObservedShotFacts(facts: [GroundedFact(
                    field: .action,
                    value: "人物转身",
                    evidenceIDs: evidenceIDs,
                    source: .onDeviceModel,
                    confidence: 0.9
                )]),
                productionPlan: ShotProductionPlan(
                    shotID: input.shot.id,
                    displayNumber: displayNumber,
                    subjectAction: "人物转身",
                    dialogueOrVO: input.transcript.first?.text,
                    sourceShotRefs: [input.shot.id],
                    isDerivedCreativePlan: true
                )
            ),
            title: "真实标题",
            summary: "真实总结"
        )
    }
}

private struct GroundedCloud: CloudStoryboardEnriching {
    let calls: GroundedCallLedger
    func enrich(
        source: VideoSource,
        asset: VideoAssetDescriptor,
        graph: ShotGraph,
        resume: CloudVideoJobCheckpoint?,
        checkpoint: @Sendable (CloudVideoJobCheckpoint) async throws -> Void
    ) async throws -> CloudStoryboardEnrichment {
        await calls.increment("cloud")
        return CloudStoryboardEnrichment(
            context: StoryboardExecutionContext(
                requestedCloudMode: .cloudDeep,
                cloudMode: .cloudDeep,
                mediaUploaded: true,
                mediaBytesUploaded: asset.fileSizeBytes,
                requestBytes: 128,
                requestCount: 2,
                inputTokens: 64,
                outputTokens: 16,
                mediaMilliseconds: 1_000,
                estimatedUSD: Decimal(string: "0.01"),
                refinementShotIDs: [graph.shots[0].id]
            ),
            evidence: [EvidenceRef(
                id: EvidenceID(rawValue: "cloud:timeline"),
                kind: .cloudTimeline,
                timeRange: graph.shots[0].timeRange,
                frameRange: nil,
                payloadRef: "cloud/timeline.json",
                source: .cloudModel,
                confidence: 0.9,
                rawText: "云端观察"
            )]
        )
    }
}

private struct GroundedProbe: VideoAssetProbing {
    let asset: VideoAssetDescriptor
    let calls: GroundedCallLedger
    func probe(_ source: VideoSource) async throws -> VideoAssetDescriptor {
        await calls.increment("probe")
        return asset
    }
}

private struct GroundedDetector: ShotBoundaryDetecting {
    let graph: ShotGraph
    let calls: GroundedCallLedger
    func detect(in asset: VideoAssetDescriptor, sourceURL: URL, quality: AnalysisQuality) async throws -> ShotGraph {
        await calls.increment("detector")
        return graph
    }
}

private struct GroundedKeyframes: ShotKeyframeSelecting {
    let shotID: ShotID
    let calls: GroundedCallLedger
    func select(in graph: ShotGraph, sourceURL: URL) async throws -> [ShotKeyframe] {
        await calls.increment("keyframes")
        return graph.shots.map { shot in
            let midpoint = (shot.timeRange.startSeconds + shot.timeRange.endSeconds) / 2
            return ShotKeyframe(
                shotID: shot.id,
                frame: SampledFrame(timestampSeconds: midpoint, jpegData: Data([1, 2, 3])),
                artifactRef: "shots/\(shot.id.rawValue)/representative.jpg"
            )
        }
    }
}

private actor GroundedCallLedger {
    private var counts: [String: Int] = [:]
    func increment(_ key: String) { counts[key, default: 0] += 1 }
    func value(_ key: String) -> Int { counts[key, default: 0] }
}

private func groundedAsset(sourceID: String) -> VideoAssetDescriptor {
    VideoAssetDescriptor(
        sourceID: sourceID, durationSeconds: 1, nominalFrameRate: 30, frameCount: 30,
        width: 720, height: 1280, timescale: 600, codec: "h264", hasAudio: true,
        fileSizeBytes: 3, fingerprint: SourceFingerprint(value: "grounded-fingerprint")
    )
}

private func groundedGraph(asset: VideoAssetDescriptor) throws -> ShotGraph {
    try ShotGraph(asset: asset, shots: [
        ShotSegment(
            id: ShotID(rawValue: "S001"),
            timeRange: MediaTimeRange(startSeconds: 0, endSeconds: 0.5),
            frameRange: FrameRange(startFrame: 0, endFrameExclusive: 15),
            transitionIn: .start, transitionOut: .cut, boundaryConfidence: 1,
            detectorEvidenceIDs: ["detector:S001"]
        ),
        ShotSegment(
            id: ShotID(rawValue: "S002"),
            timeRange: MediaTimeRange(startSeconds: 0.5, endSeconds: 1),
            frameRange: FrameRange(startFrame: 15, endFrameExclusive: 30),
            transitionIn: .cut, transitionOut: .end, boundaryConfidence: 1,
            detectorEvidenceIDs: ["detector:S002"]
        ),
    ])
}
