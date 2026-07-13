import AnalysisStore
import Foundation
import Testing
import VideoUnderstanding

@Test func analysisStoreResumesOnlyVerifiedAtomicCheckpoints() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramAnalysisStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try AnalysisArtifactStore(rootURL: root)
    var run = try await store.createRun(
        clipID: "clip-1",
        fingerprint: SourceFingerprint(value: "fingerprint-1"),
        pipelineVersion: "storyboard-v2",
        runID: "run-1"
    )
    run = try await store.commit(
        stage: .assetProbe,
        artifact: Data("{\"duration\":2}".utf8),
        for: run
    )

    #expect(run.completedStages == [.assetProbe])
    let resumed = try await store.loadResumableRun(
        clipID: "clip-1",
        fingerprint: SourceFingerprint(value: "fingerprint-1"),
        pipelineVersion: "storyboard-v2"
    )
    #expect(resumed?.id == "run-1")

    let artifactURL = await store.artifactURL(runID: run.id, stage: .assetProbe)
    try Data("corrupt".utf8).write(to: artifactURL)
    let rejected = try await store.loadResumableRun(
        clipID: "clip-1",
        fingerprint: SourceFingerprint(value: "fingerprint-1"),
        pipelineVersion: "storyboard-v2"
    )
    #expect(rejected == nil)
}
