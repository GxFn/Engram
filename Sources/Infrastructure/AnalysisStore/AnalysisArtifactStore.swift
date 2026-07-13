import CryptoKit
import Foundation
import VideoUnderstanding

public enum AnalysisArtifactStoreError: Error, Hashable, Sendable {
    case unsafeIdentifier
    case runMismatch
    case checkpointConflict(AnalysisStage)
    case invalidManifest
}

public actor AnalysisArtifactStore {
    private let rootURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let schemaVersion: Int

    public init(
        rootURL: URL,
        fileManager: FileManager = .default,
        schemaVersion: Int = 1,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.schemaVersion = schemaVersion
        self.now = now
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func createRun(
        clipID: String,
        fingerprint: SourceFingerprint,
        pipelineVersion: String,
        runID: String = UUID().uuidString
    ) throws -> AnalysisRun {
        try Self.validateIdentifier(clipID)
        try Self.validateIdentifier(runID)
        let timestamp = now()
        let run = AnalysisRun(
            id: runID,
            clipID: clipID,
            fingerprint: fingerprint,
            schemaVersion: schemaVersion,
            pipelineVersion: pipelineVersion,
            status: .running,
            currentStage: .assetProbe,
            completedStages: [],
            checkpoints: [],
            startedAt: timestamp,
            updatedAt: timestamp
        )
        try fileManager.createDirectory(at: runDirectory(clipID: clipID, runID: runID), withIntermediateDirectories: true)
        try writeManifest(run)
        return run
    }

    public func commit(stage: AnalysisStage, artifact: Data, for run: AnalysisRun) throws -> AnalysisRun {
        try Self.validateIdentifier(run.clipID)
        try Self.validateIdentifier(run.id)
        let directory = runDirectory(clipID: run.clipID, runID: run.id)
        let finalURL = directory.appendingPathComponent(Self.fileName(for: stage))
        let checksum = Self.sha256(artifact)

        if fileManager.fileExists(atPath: finalURL.path) {
            let existing = try Data(contentsOf: finalURL)
            guard Self.sha256(existing) == checksum else {
                throw AnalysisArtifactStoreError.checkpointConflict(stage)
            }
        } else {
            try writeAtomically(artifact, to: finalURL)
        }

        var checkpoints = run.checkpoints.filter { $0.stage != stage }
        checkpoints.append(ArtifactCheckpoint(
            stage: stage,
            relativePath: Self.fileName(for: stage),
            sha256: checksum,
            byteCount: artifact.count,
            completedAt: now()
        ))
        checkpoints.sort { Self.stageIndex($0.stage) < Self.stageIndex($1.stage) }
        let completedStages = checkpoints.map(\.stage)
        let next = AnalysisStage.allCases.first { !completedStages.contains($0) } ?? .completed
        let updated = AnalysisRun(
            id: run.id,
            clipID: run.clipID,
            fingerprint: run.fingerprint,
            schemaVersion: run.schemaVersion,
            pipelineVersion: run.pipelineVersion,
            status: next == .completed ? .completed : .running,
            currentStage: next,
            completedStages: completedStages,
            checkpoints: checkpoints,
            startedAt: run.startedAt,
            updatedAt: now(),
            retryCount: run.retryCount,
            mediaBytesUploaded: run.mediaBytesUploaded,
            degradationNotes: run.degradationNotes,
            cloudTelemetry: run.cloudTelemetry
        )
        try writeManifest(updated)
        return updated
    }

    public func loadResumableRun(
        clipID: String,
        fingerprint: SourceFingerprint,
        pipelineVersion: String
    ) throws -> AnalysisRun? {
        try Self.validateIdentifier(clipID)
        let clipDirectory = rootURL.appendingPathComponent(clipID, isDirectory: true)
        guard let runDirectories = try? fileManager.contentsOfDirectory(
            at: clipDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [AnalysisRun] = []
        for directory in runDirectories {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: manifestURL),
                  let run = try? decoder.decode(AnalysisRun.self, from: data),
                  run.clipID == clipID,
                  run.fingerprint == fingerprint,
                  run.pipelineVersion == pipelineVersion,
                  run.schemaVersion == schemaVersion,
                  try validateCheckpoints(run)
            else { continue }
            candidates.append(run)
        }
        return candidates.max { $0.updatedAt < $1.updatedAt }
    }

    public func artifactURL(runID: String, stage: AnalysisStage) -> URL {
        let clipDirectories = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for clipDirectory in clipDirectories {
            let candidate = clipDirectory
                .appendingPathComponent(runID, isDirectory: true)
                .appendingPathComponent(Self.fileName(for: stage))
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return rootURL.appendingPathComponent(runID).appendingPathComponent(Self.fileName(for: stage))
    }

    public func loadArtifact<T: Decodable & Sendable>(
        _ type: T.Type,
        stage: AnalysisStage,
        from run: AnalysisRun
    ) throws -> T? {
        guard let checkpoint = run.checkpoints.first(where: { $0.stage == stage }) else {
            return nil
        }
        let url = runDirectory(clipID: run.clipID, runID: run.id)
            .appendingPathComponent(checkpoint.relativePath)
        let data = try Data(contentsOf: url)
        guard data.count == checkpoint.byteCount, Self.sha256(data) == checkpoint.sha256 else {
            throw AnalysisArtifactStoreError.invalidManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    public func saveAuxiliaryArtifact<T: Encodable & Sendable>(
        _ value: T,
        name: String,
        for run: AnalysisRun
    ) throws {
        try Self.validateIdentifier(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try writeAtomically(
            encoder.encode(value),
            to: runDirectory(clipID: run.clipID, runID: run.id)
                .appendingPathComponent("aux-\(name).json")
        )
    }

    public func loadAuxiliaryArtifact<T: Decodable & Sendable>(
        _ type: T.Type,
        name: String,
        from run: AnalysisRun
    ) throws -> T? {
        try Self.validateIdentifier(name)
        let url = runDirectory(clipID: run.clipID, runID: run.id)
            .appendingPathComponent("aux-\(name).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    public func deleteAuxiliaryArtifact(name: String, from run: AnalysisRun) throws {
        try Self.validateIdentifier(name)
        let url = runDirectory(clipID: run.clipID, runID: run.id)
            .appendingPathComponent("aux-\(name).json")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func recordCloudTelemetry(
        _ telemetry: AnalysisCloudTelemetry,
        for run: AnalysisRun
    ) throws -> AnalysisRun {
        let updated = AnalysisRun(
            id: run.id,
            clipID: run.clipID,
            fingerprint: run.fingerprint,
            schemaVersion: run.schemaVersion,
            pipelineVersion: run.pipelineVersion,
            status: run.status,
            currentStage: run.currentStage,
            completedStages: run.completedStages,
            checkpoints: run.checkpoints,
            startedAt: run.startedAt,
            updatedAt: now(),
            retryCount: run.retryCount,
            mediaBytesUploaded: telemetry.mediaBytesUploaded ?? run.mediaBytesUploaded,
            degradationNotes: run.degradationNotes,
            cloudTelemetry: telemetry
        )
        try writeManifest(updated)
        return updated
    }

    public func saveShotArtifact<T: Codable & Sendable>(
        _ value: T,
        stage: AnalysisStage,
        shotID: ShotID,
        cacheKey: String,
        for run: AnalysisRun
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(value)
        let envelope = ShotArtifactEnvelope(
            shotID: shotID.rawValue,
            stage: stage,
            cacheKey: cacheKey,
            payload: payload,
            payloadSHA256: Self.sha256(payload),
            completedAt: now()
        )
        try writeAtomically(
            encoder.encode(envelope),
            to: shotArtifactURL(stage: stage, shotID: shotID, run: run)
        )
    }

    public func loadShotArtifact<T: Codable & Sendable>(
        _ type: T.Type,
        stage: AnalysisStage,
        shotID: ShotID,
        cacheKey: String,
        from run: AnalysisRun
    ) throws -> T? {
        let url = shotArtifactURL(stage: stage, shotID: shotID, run: run)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(ShotArtifactEnvelope.self, from: Data(contentsOf: url))
            guard envelope.shotID == shotID.rawValue,
                  envelope.stage == stage,
                  envelope.cacheKey == cacheKey
            else { return nil }
            guard Self.sha256(envelope.payload) == envelope.payloadSHA256 else {
                throw AnalysisArtifactStoreError.invalidManifest
            }
            return try decoder.decode(T.self, from: envelope.payload)
        } catch let error as AnalysisArtifactStoreError {
            throw error
        } catch {
            throw AnalysisArtifactStoreError.invalidManifest
        }
    }

    public func invalidateShotArtifacts(
        stages: Set<AnalysisStage>,
        shotIDs: Set<ShotID>,
        from run: AnalysisRun
    ) throws {
        for shotID in shotIDs {
            for stage in stages {
                let url = shotArtifactURL(stage: stage, shotID: shotID, run: run)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
        }
    }

    public func invalidate(stages: Set<AnalysisStage>, from run: AnalysisRun) throws -> AnalysisRun {
        let directory = runDirectory(clipID: run.clipID, runID: run.id)
        let retained = run.checkpoints.filter { !stages.contains($0.stage) }
        for checkpoint in run.checkpoints where stages.contains(checkpoint.stage) {
            let url = directory.appendingPathComponent(checkpoint.relativePath)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        let completedStages = retained.map(\.stage)
        let next = AnalysisStage.allCases.first { !completedStages.contains($0) } ?? .completed
        let updated = AnalysisRun(
            id: run.id,
            clipID: run.clipID,
            fingerprint: run.fingerprint,
            schemaVersion: run.schemaVersion,
            pipelineVersion: run.pipelineVersion,
            status: next == .completed ? .completed : .running,
            currentStage: next,
            completedStages: completedStages,
            checkpoints: retained,
            startedAt: run.startedAt,
            updatedAt: now(),
            retryCount: run.retryCount + 1,
            mediaBytesUploaded: run.mediaBytesUploaded,
            degradationNotes: run.degradationNotes,
            cloudTelemetry: run.cloudTelemetry
        )
        try writeManifest(updated)
        return updated
    }

    public func deleteArtifacts(clipID: String) throws {
        try Self.validateIdentifier(clipID)
        let directory = rootURL.appendingPathComponent(clipID, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func validateCheckpoints(_ run: AnalysisRun) throws -> Bool {
        let directory = runDirectory(clipID: run.clipID, runID: run.id)
        for checkpoint in run.checkpoints {
            let url = directory.appendingPathComponent(checkpoint.relativePath)
            guard let data = try? Data(contentsOf: url),
                  data.count == checkpoint.byteCount,
                  Self.sha256(data) == checkpoint.sha256
            else { return false }
        }
        return true
    }

    private func writeManifest(_ run: AnalysisRun) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(run)
        try writeAtomically(data, to: runDirectory(clipID: run.clipID, runID: run.id).appendingPathComponent("manifest.json"))
    }

    private func writeAtomically(_ data: Data, to finalURL: URL) throws {
        try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(finalURL.lastPathComponent).\(UUID().uuidString).tmp")
        fileManager.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if fileManager.fileExists(atPath: finalURL.path) {
                _ = try fileManager.replaceItemAt(finalURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: finalURL)
            }
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func runDirectory(clipID: String, runID: String) -> URL {
        rootURL.appendingPathComponent(clipID, isDirectory: true).appendingPathComponent(runID, isDirectory: true)
    }

    private func shotArtifactURL(stage: AnalysisStage, shotID: ShotID, run: AnalysisRun) -> URL {
        let key = Self.sha256(Data(shotID.rawValue.utf8))
        return runDirectory(clipID: run.clipID, runID: run.id)
            .appendingPathComponent("shots", isDirectory: true)
            .appendingPathComponent("\(key)-\(stage.rawValue).json")
    }

    private static func fileName(for stage: AnalysisStage) -> String {
        "\(stage.rawValue).json"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stageIndex(_ stage: AnalysisStage) -> Int {
        AnalysisStage.allCases.firstIndex(of: stage) ?? Int.max
    }

    private static func validateIdentifier(_ value: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw AnalysisArtifactStoreError.unsafeIdentifier
        }
    }
}

private struct ShotArtifactEnvelope: Codable, Sendable {
    let shotID: String
    let stage: AnalysisStage
    let cacheKey: String
    let payload: Data
    let payloadSHA256: String
    let completedAt: Date
}
