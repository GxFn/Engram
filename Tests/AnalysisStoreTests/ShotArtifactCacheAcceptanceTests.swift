import AnalysisStore
import Foundation
import Testing
import VideoUnderstanding

@Test func shotArtifactCacheVerifiesKeyChecksumAndInvalidation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramShotArtifactCacheAcceptance-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AnalysisArtifactStore(rootURL: root)
    let run = try await store.createRun(
        clipID: "shot-cache-clip",
        fingerprint: SourceFingerprint(value: "shot-cache-fingerprint"),
        pipelineVersion: "shot-cache-v1",
        runID: "shot-cache-run"
    )
    let shotID = ShotID(rawValue: "S001")
    let payload = ShotCacheTestPayload(value: "grounded output")

    try await store.saveShotArtifact(
        payload,
        stage: .shotUnderstanding,
        shotID: shotID,
        cacheKey: "input-v1",
        for: run
    )

    let loaded = try await store.loadShotArtifact(
        ShotCacheTestPayload.self,
        stage: .shotUnderstanding,
        shotID: shotID,
        cacheKey: "input-v1",
        from: run
    )
    #expect(loaded == payload)
    let stale = try await store.loadShotArtifact(
        ShotCacheTestPayload.self,
        stage: .shotUnderstanding,
        shotID: shotID,
        cacheKey: "changed-input",
        from: run
    )
    #expect(stale == nil)

    let shotsDirectory = root
        .appendingPathComponent(run.clipID, isDirectory: true)
        .appendingPathComponent(run.id, isDirectory: true)
        .appendingPathComponent("shots", isDirectory: true)
    let cacheURL = try #require(
        FileManager.default.contentsOfDirectory(at: shotsDirectory, includingPropertiesForKeys: nil).first
    )
    try Data("corrupt".utf8).write(to: cacheURL)
    await #expect(throws: AnalysisArtifactStoreError.invalidManifest) {
        _ = try await store.loadShotArtifact(
            ShotCacheTestPayload.self,
            stage: .shotUnderstanding,
            shotID: shotID,
            cacheKey: "input-v1",
            from: run
        )
    }

    try await store.saveShotArtifact(
        payload,
        stage: .shotUnderstanding,
        shotID: shotID,
        cacheKey: "input-v1",
        for: run
    )
    try await store.invalidateShotArtifacts(
        stages: [.shotUnderstanding],
        shotIDs: [shotID],
        from: run
    )
    let invalidated = try await store.loadShotArtifact(
        ShotCacheTestPayload.self,
        stage: .shotUnderstanding,
        shotID: shotID,
        cacheKey: "input-v1",
        from: run
    )
    #expect(invalidated == nil)
}

private struct ShotCacheTestPayload: Codable, Equatable, Sendable {
    let value: String
}
