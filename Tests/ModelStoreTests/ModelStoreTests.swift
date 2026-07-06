import EngineKit
@testable import ModelStore
import Testing
import Foundation

@Test func localURLUsesDeterministicModelIDPath() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let store = ModelStore(modelsDirectory: modelsDirectory)
    let url = try await store.localURL(for: ModelCatalog.qwen3_4B_4bit)

    #expect(url == modelsDirectory
        .appendingPathComponent("mlx-community", isDirectory: true)
        .appendingPathComponent("Qwen3-4B-4bit", isDirectory: true)
    )
    #expect(FileManager.default.fileExists(atPath: modelsDirectory.path))
}

@Test func downloadedModelsScanKnownCatalogDirectories() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let store = ModelStore(modelsDirectory: modelsDirectory)
    let model = ModelCatalog.qwen3_1_7B_4bit
    let modelDirectory = try makeModelDirectory(for: model, in: modelsDirectory)
    try writeFile(named: "weights.safetensors", bytes: 5, in: modelDirectory)

    let downloaded = try await store.downloadedModels()

    #expect(downloaded == [model])
    #expect(try await store.isDownloaded(model))
}

@Test func downloadedModelsIncludeManifestBackedDirectories() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let store = ModelStore(modelsDirectory: modelsDirectory)
    let model = ModelIdentity(
        id: "custom/local-model",
        family: "custom",
        quantization: "4bit",
        contextLength: 4_096,
        estimatedMemoryBytes: 256_000_000
    )
    let manifestDirectory = modelsDirectory.appendingPathComponent("Imported/custom-model", isDirectory: true)
    try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
    try writeManifest(for: model, in: manifestDirectory)
    try writeFile(named: "weights.safetensors", bytes: 5, in: manifestDirectory)

    let downloaded = try await store.downloadedModels()

    #expect(downloaded == [model])
}

@Test func manifestBackedModelsReportDownloadedStorageAndDeleteFromActualDirectory() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let store = ModelStore(modelsDirectory: modelsDirectory)
    let model = ModelIdentity(
        id: "custom/local-model",
        family: "custom",
        quantization: "4bit",
        contextLength: 4_096,
        estimatedMemoryBytes: 256_000_000
    )
    let manifestDirectory = modelsDirectory.appendingPathComponent("Imported/custom-model", isDirectory: true)
    try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
    try writeManifest(for: model, in: manifestDirectory)
    try writeFile(named: "weights.safetensors", bytes: 9, in: manifestDirectory)

    #expect(try await store.isDownloaded(model))
    #expect(try await store.storageBytes(for: model) > 9)

    try await store.delete(model)

    #expect(try await store.isDownloaded(model) == false)
    #expect(try await store.storageBytes(for: model) == 0)
    #expect(FileManager.default.fileExists(atPath: manifestDirectory.path) == false)
}

@Test func downloadedModelsIgnoreManifestDirectoriesWithoutPayload() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let store = ModelStore(modelsDirectory: modelsDirectory)
    let model = ModelIdentity(
        id: "custom/metadata-only",
        family: "custom",
        quantization: "4bit",
        contextLength: 4_096,
        estimatedMemoryBytes: 256_000_000
    )
    let manifestDirectory = modelsDirectory.appendingPathComponent("Imported/metadata-only", isDirectory: true)
    try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
    try writeManifest(for: model, in: manifestDirectory)

    let downloaded = try await store.downloadedModels()

    #expect(downloaded.isEmpty)
}

@Test func storageBytesIncludeNestedRegularFiles() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let store = ModelStore(modelsDirectory: modelsDirectory)
    let model = ModelCatalog.qwen3_4B_4bit
    let modelDirectory = try makeModelDirectory(for: model, in: modelsDirectory)
    let shardDirectory = modelDirectory.appendingPathComponent("shards", isDirectory: true)
    try FileManager.default.createDirectory(at: shardDirectory, withIntermediateDirectories: true)
    try writeFile(named: "part-0001.safetensors", bytes: 7, in: modelDirectory)
    try writeFile(named: "part-0002.safetensors", bytes: 11, in: shardDirectory)

    #expect(try await store.storageBytes(for: model) == 18)
}

@Test func deleteRemovesModelDirectoryAndDownloadState() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let store = ModelStore(modelsDirectory: modelsDirectory)
    let model = ModelCatalog.qwen3_4B_4bit
    let modelDirectory = try makeModelDirectory(for: model, in: modelsDirectory)
    try writeFile(named: "weights.safetensors", bytes: 3, in: modelDirectory)

    try await store.delete(model)

    #expect(try await store.storageBytes(for: model) == 0)
    #expect(try await store.isDownloaded(model) == false)
    #expect(FileManager.default.fileExists(atPath: modelDirectory.path) == false)
}

@Test func downloadReturnsForExistingLocalPayloadWithoutRemoteFetch() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let downloader = ScriptedSnapshotDownloader(steps: [.success])
    let store = ModelStore(modelsDirectory: modelsDirectory, snapshotDownloader: downloader)
    let downloadedModel = ModelCatalog.qwen3_1_7B_4bit
    let downloadedDirectory = try makeModelDirectory(for: downloadedModel, in: modelsDirectory)
    try writeFile(named: "weights.safetensors", bytes: 3, in: downloadedDirectory)

    let result = try await store.download(downloadedModel)

    #expect(result.localURL == downloadedDirectory)
    #expect(await downloader.callCount == 0)
}

@Test func downloadFetchesPublicSnapshotRegistersCanonicalModelAndReportsProgress() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let downloader = ScriptedSnapshotDownloader(steps: [.success])
    let recorder = DownloadStateRecorder()
    let store = ModelStore(modelsDirectory: modelsDirectory, snapshotDownloader: downloader)
    let model = ModelCatalog.qwen3_1_7B_4bit

    let result = try await store.download(model) { recorder.record($0) }
    let expectedDirectory = modelsDirectory
        .appendingPathComponent("mlx-community", isDirectory: true)
        .appendingPathComponent("Qwen3-1.7B-4bit", isDirectory: true)

    #expect(result.model == model)
    #expect(result.localURL == expectedDirectory)
    #expect(try await store.isDownloaded(model))
    #expect(try await store.downloadedModels() == [model])
    #expect(FileManager.default.fileExists(
        atPath: expectedDirectory.appendingPathComponent(".engram-model.json").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: expectedDirectory.appendingPathComponent("model.safetensors").path
    ))
    #expect(recorder.states.contains { $0.fractionCompleted == 0.25 })
    #expect(recorder.states.last?.fractionCompleted == 1)
    #expect(await downloader.callCount == 1)
}

@Test func downloadFailureDoesNotCreateDownloadedState() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let downloader = ScriptedSnapshotDownloader(steps: [.failure])
    let store = ModelStore(modelsDirectory: modelsDirectory, snapshotDownloader: downloader)
    let model = ModelCatalog.qwen3_1_7B_4bit

    do {
        try await store.download(model)
        Issue.record("Expected public snapshot failure")
    } catch TestDownloadError.networkUnavailable {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(try await store.isDownloaded(model) == false)
    #expect(try await store.storageBytes(for: model) == 0)
}

@Test func downloadRejectsIncompleteSnapshotWithoutDownloadedState() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let downloader = ScriptedSnapshotDownloader(steps: [.invalidSnapshot])
    let store = ModelStore(modelsDirectory: modelsDirectory, snapshotDownloader: downloader)
    let model = ModelCatalog.qwen3_1_7B_4bit

    do {
        try await store.download(model)
        Issue.record("Expected incomplete snapshot failure")
    } catch ModelDownloadError.incompleteSnapshot(let modelID) {
        #expect(modelID == model.id)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(try await store.isDownloaded(model) == false)
    #expect(try await store.storageBytes(for: model) == 0)
}

@Test func downloadCancellationDoesNotInstallPartialSnapshot() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let downloader = ScriptedSnapshotDownloader(steps: [.cancelled])
    let store = ModelStore(modelsDirectory: modelsDirectory, snapshotDownloader: downloader)
    let model = ModelCatalog.qwen3_1_7B_4bit

    do {
        try await store.download(model)
        Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(try await store.isDownloaded(model) == false)
}

@Test func downloadCanRetryAfterNetworkFailure() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let downloader = ScriptedSnapshotDownloader(steps: [.failure, .success])
    let store = ModelStore(modelsDirectory: modelsDirectory, snapshotDownloader: downloader)
    let model = ModelCatalog.qwen3_1_7B_4bit

    do {
        try await store.download(model)
        Issue.record("Expected first download attempt to fail")
    } catch TestDownloadError.networkUnavailable {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let result = try await store.download(model)

    #expect(result.model == model)
    #expect(try await store.isDownloaded(model))
    #expect(await downloader.callCount == 2)
}

@Test func installLocalModelCopiesVerifiedFolderAndWritesManifest() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let store = ModelStore(modelsDirectory: modelsDirectory)
    let model = ModelCatalog.qwen3_1_7B_4bit
    let sourceDirectory = modelsDirectory
        .deletingLastPathComponent()
        .appendingPathComponent("DownloadedModel", isDirectory: true)
    try makeModelFixture(at: sourceDirectory)

    let result = try await store.installLocalModel(model, from: sourceDirectory)
    let expectedDirectory = modelsDirectory
        .appendingPathComponent("mlx-community", isDirectory: true)
        .appendingPathComponent("Qwen3-1.7B-4bit", isDirectory: true)

    #expect(result.model == model)
    #expect(result.localURL == expectedDirectory)
    #expect(result.storageBytes == (try await store.storageBytes(for: model)))
    #expect(try await store.isDownloaded(model))
    #expect(try await store.downloadedModels() == [model])
    #expect(FileManager.default.fileExists(atPath: sourceDirectory.path))
    #expect(FileManager.default.fileExists(
        atPath: expectedDirectory.appendingPathComponent(".engram-model.json").path
    ))
}

@Test func installLocalModelRejectsInvalidFolderWithoutDownloadedState() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let store = ModelStore(modelsDirectory: modelsDirectory)
    let model = ModelCatalog.qwen3_1_7B_4bit
    let invalidDirectory = modelsDirectory
        .deletingLastPathComponent()
        .appendingPathComponent("InvalidModel", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
    try writeFile(named: "config.json", bytes: 2, in: invalidDirectory)

    do {
        try await store.installLocalModel(model, from: invalidDirectory)
        Issue.record("Expected invalid model folder to fail")
    } catch ModelInstallationError.missingRequiredFiles(let missingFiles) {
        #expect(missingFiles.contains("tokenizer.json or tokenizer.model"))
        #expect(missingFiles.contains("model weights"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(try await store.isDownloaded(model) == false)
    #expect(try await store.storageBytes(for: model) == 0)
}

@Test func deviceCapabilityRecommendsFourBOnlyAtSevenGiBOrAbove() {
    let belowThreshold = DeviceCapability(
        physicalMemoryBytes: DeviceCapability.qwen3FourBRecommendedMemoryBytes - 1
    )
    let atThreshold = DeviceCapability(
        physicalMemoryBytes: DeviceCapability.qwen3FourBRecommendedMemoryBytes
    )

    #expect(belowThreshold.recommendedModel == ModelCatalog.qwen3_1_7B_4bit)
    #expect(atThreshold.recommendedModel == ModelCatalog.qwen3_4B_4bit)
}

@Test func deviceCapabilityUsesSafetyFactorForCanRunChecks() {
    let model = ModelIdentity(
        id: "test/model",
        family: "test",
        quantization: "none",
        contextLength: 128,
        estimatedMemoryBytes: 1_000
    )

    #expect(DeviceCapability(physicalMemoryBytes: 1_399).canRun(model) == false)
    #expect(DeviceCapability(physicalMemoryBytes: 1_400).canRun(model))
    #expect(DeviceCapability(physicalMemoryBytes: 2_000).requiredMemoryBytes(for: model) == 1_400)
}

@Test func downloadStateReportsBoundedFractions() {
    #expect(DownloadState(completedBytes: 25, totalBytes: 100).fractionCompleted == 0.25)
    #expect(DownloadState(completedBytes: 125, totalBytes: 100).fractionCompleted == 1)
    #expect(DownloadState(completedBytes: 25, totalBytes: nil).fractionCompleted == nil)
}

private func makeTemporaryModelsDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramModelStoreTests-\(UUID().uuidString)", isDirectory: true)
    let modelsDirectory = root.appendingPathComponent("Models", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    return modelsDirectory
}

private func makeModelDirectory(for model: ModelIdentity, in modelsDirectory: URL) throws -> URL {
    let modelDirectory = model.id.split(separator: "/").reduce(modelsDirectory) { url, component in
        url.appendingPathComponent(String(component), isDirectory: true)
    }

    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    return modelDirectory
}

private func writeFile(named name: String, bytes: Int, in directory: URL) throws {
    let data = Data(repeating: 0x41, count: bytes)
    try data.write(to: directory.appendingPathComponent(name, isDirectory: false))
}

private func makeModelFixture(at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writeFile(named: "config.json", bytes: 2, in: directory)
    try writeFile(named: "tokenizer.json", bytes: 3, in: directory)
    try writeFile(named: "model.safetensors", bytes: 5, in: directory)
}

private func writeManifest(for model: ModelIdentity, in directory: URL) throws {
    let data = try JSONEncoder().encode(model)
    try data.write(to: directory.appendingPathComponent(".engram-model.json", isDirectory: false))
}

private enum SnapshotStep: Sendable {
    case success
    case invalidSnapshot
    case failure
    case cancelled
}

private enum TestDownloadError: Error, LocalizedError {
    case networkUnavailable

    var errorDescription: String? {
        "Network unavailable."
    }
}

private actor ScriptedSnapshotDownloader: ModelSnapshotDownloading {
    private var steps: [SnapshotStep]
    private var calls = 0

    init(steps: [SnapshotStep]) {
        self.steps = steps
    }

    var callCount: Int {
        calls
    }

    func downloadSnapshot(
        for model: ModelIdentity,
        into downloadBase: URL,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let step: SnapshotStep
        calls += 1
        step = steps.isEmpty ? .success : steps.removeFirst()

        let snapshot = snapshotDirectory(for: model, in: downloadBase)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)

        let firstProgress = Progress(totalUnitCount: 100)
        firstProgress.completedUnitCount = 25
        progressHandler(firstProgress)

        switch step {
        case .success:
            try makeModelFixture(at: snapshot)
        case .invalidSnapshot:
            try writeFile(named: "config.json", bytes: 2, in: snapshot)
        case .failure:
            throw TestDownloadError.networkUnavailable
        case .cancelled:
            try writeFile(named: "config.json", bytes: 2, in: snapshot)
            throw CancellationError()
        }

        let finalProgress = Progress(totalUnitCount: 100)
        finalProgress.completedUnitCount = 100
        progressHandler(finalProgress)
        return snapshot
    }

    private func snapshotDirectory(for model: ModelIdentity, in downloadBase: URL) -> URL {
        model.id.split(separator: "/").reduce(
            downloadBase.appendingPathComponent("models", isDirectory: true)
        ) { url, component in
            url.appendingPathComponent(String(component), isDirectory: true)
        }
    }
}

private final class DownloadStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStates: [DownloadState] = []

    var states: [DownloadState] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStates
    }

    func record(_ state: DownloadState) {
        lock.lock()
        recordedStates.append(state)
        lock.unlock()
    }
}
