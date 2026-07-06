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

@Test func downloadReturnsForLocalPayloadAndDefersRemoteFetch() async throws {
    let modelsDirectory = try makeTemporaryModelsDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory.deletingLastPathComponent()) }

    let store = ModelStore(modelsDirectory: modelsDirectory)
    let downloadedModel = ModelCatalog.qwen3_1_7B_4bit
    let downloadedDirectory = try makeModelDirectory(for: downloadedModel, in: modelsDirectory)
    try writeFile(named: "weights.safetensors", bytes: 3, in: downloadedDirectory)

    try await store.download(downloadedModel)

    do {
        try await store.download(ModelCatalog.qwen3_4B_4bit)
        Issue.record("Expected missing remote download to fail explicitly")
    } catch EngineError.notImplemented(let message) {
        #expect(message.contains("remote model download deferred"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
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

private func writeManifest(for model: ModelIdentity, in directory: URL) throws {
    let data = try JSONEncoder().encode(model)
    try data.write(to: directory.appendingPathComponent(".engram-model.json", isDirectory: false))
}
