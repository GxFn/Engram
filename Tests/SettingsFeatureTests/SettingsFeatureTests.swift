import EngineKit
import Foundation
@testable import SettingsFeature
import Testing

@MainActor
@Test func settingsRefreshSelectsRecommendedModelWhenStoredSelectionIsMissing() async {
    let registry = FakeModelRegistry(models: [
        managedModel(otherModel, isRecommended: false),
        managedModel(recommendedModel, isRecommended: true),
    ])
    var appliedModelIDs: [String] = []
    let viewModel = SettingsViewModel(
        engines: [fakeEngine],
        selectedModelID: "missing/model",
        selectedEngineID: fakeEngine.id,
        generationConfig: .default,
        physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        recommendedModelID: recommendedModel.id,
        client: registry.client,
        applyActiveModel: { appliedModelIDs.append($0.id) }
    )

    await viewModel.refresh()

    #expect(viewModel.models.map(\.id) == [recommendedModel.id, otherModel.id])
    #expect(viewModel.selectedModelID == recommendedModel.id)
    #expect(appliedModelIDs == [recommendedModel.id])
}

@MainActor
@Test func settingsGenerationConfigClampsAndPropagates() {
    var appliedConfigs: [GenerationConfig] = []
    let viewModel = SettingsViewModel(
        engines: [fakeEngine],
        selectedModelID: recommendedModel.id,
        selectedEngineID: fakeEngine.id,
        generationConfig: GenerationConfig(temperature: 0.7, topP: 0.9, maxTokens: 128),
        physicalMemoryBytes: 1,
        recommendedModelID: recommendedModel.id,
        applyGenerationConfig: { appliedConfigs.append($0) }
    )

    viewModel.setTemperature(9)
    viewModel.setTopP(0.01)
    viewModel.setMaxTokens(99_999)

    #expect(viewModel.generationConfig.temperature == 2)
    #expect(viewModel.generationConfig.topP == 0.05)
    #expect(viewModel.generationConfig.maxTokens == 4_096)
    #expect(appliedConfigs.last == viewModel.generationConfig)
}

@MainActor
@Test func settingsDownloadFailureIsExplicitAndDoesNotFakeDownloadedState() async {
    let row = managedModel(recommendedModel, isDownloaded: false, isRecommended: true)
    let registry = FakeModelRegistry(
        models: [row],
        downloadError: TestDownloadError.networkUnavailable
    )
    let viewModel = SettingsViewModel(
        engines: [fakeEngine],
        selectedModelID: recommendedModel.id,
        selectedEngineID: fakeEngine.id,
        generationConfig: .default,
        physicalMemoryBytes: 1,
        recommendedModelID: recommendedModel.id,
        client: registry.client
    )
    await viewModel.refresh()

    guard let model = viewModel.models.first else {
        Issue.record("Expected a model row")
        return
    }

    await viewModel.download(model)

    #expect(viewModel.operationModelID == nil)
    #expect(viewModel.errorMessage == "Network unavailable.")
    #expect(viewModel.models.first?.isDownloaded == false)
}

@MainActor
@Test func settingsDownloadProgressRefreshesStateAndSelectsModel() async {
    let registry = FakeModelRegistry(models: [
        managedModel(otherModel, isDownloaded: true, isRecommended: false),
        managedModel(recommendedModel, isDownloaded: false, isRecommended: true),
    ])
    var appliedModelIDs: [String] = []
    let viewModel = SettingsViewModel(
        engines: [fakeEngine],
        selectedModelID: otherModel.id,
        selectedEngineID: fakeEngine.id,
        generationConfig: .default,
        physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        recommendedModelID: recommendedModel.id,
        client: registry.client,
        applyActiveModel: { appliedModelIDs.append($0.id) }
    )
    await viewModel.refresh()

    let model = try! #require(viewModel.models.first { $0.id == recommendedModel.id })

    await viewModel.download(model)
    await Task.yield()

    #expect(await registry.downloadedModelIDs == [recommendedModel.id])
    #expect(viewModel.downloadProgress?.fractionCompleted == 1)
    #expect(viewModel.models.first(where: { $0.id == recommendedModel.id })?.isDownloaded == true)
    #expect(viewModel.selectedModelID == recommendedModel.id)
    #expect(appliedModelIDs == [recommendedModel.id])
    #expect(viewModel.errorMessage == nil)
}

@MainActor
@Test func settingsCancelledDownloadDoesNotFakeDownloadedState() async {
    let registry = FakeModelRegistry(
        models: [managedModel(recommendedModel, isDownloaded: false, isRecommended: true)],
        downloadError: CancellationError()
    )
    let viewModel = SettingsViewModel(
        engines: [fakeEngine],
        selectedModelID: recommendedModel.id,
        selectedEngineID: fakeEngine.id,
        generationConfig: .default,
        physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        recommendedModelID: recommendedModel.id,
        client: registry.client
    )
    await viewModel.refresh()

    let model = try! #require(viewModel.models.first)

    await viewModel.download(model)

    #expect(viewModel.errorMessage == "Stopped.")
    #expect(viewModel.models.first?.isDownloaded == false)
    #expect(viewModel.operationModelID == nil)
}

@MainActor
@Test func settingsLocalImportRefreshesModelStateAndSelectsModel() async {
    let registry = FakeModelRegistry(models: [
        managedModel(otherModel, isDownloaded: true, isRecommended: false),
        managedModel(recommendedModel, isDownloaded: false, isRecommended: true),
    ])
    var appliedModelIDs: [String] = []
    let viewModel = SettingsViewModel(
        engines: [fakeEngine],
        selectedModelID: otherModel.id,
        selectedEngineID: fakeEngine.id,
        generationConfig: .default,
        physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        recommendedModelID: recommendedModel.id,
        client: registry.client,
        applyActiveModel: { appliedModelIDs.append($0.id) }
    )
    await viewModel.refresh()

    guard let model = viewModel.models.first(where: { $0.id == recommendedModel.id }) else {
        Issue.record("Expected recommended model row")
        return
    }

    await viewModel.installLocalModel(model, from: URL(fileURLWithPath: "/tmp/VerifiedModel"))

    #expect(await registry.importedModelIDs == [recommendedModel.id])
    #expect(viewModel.models.first(where: { $0.id == recommendedModel.id })?.isDownloaded == true)
    #expect(viewModel.selectedModelID == recommendedModel.id)
    #expect(appliedModelIDs == [recommendedModel.id])
    #expect(viewModel.errorMessage == nil)
    #expect(viewModel.operationModelID == nil)
}

@MainActor
@Test func settingsLocalImportFailureDoesNotFakeDownloadedState() async {
    let registry = FakeModelRegistry(
        models: [managedModel(recommendedModel, isDownloaded: false, isRecommended: true)],
        installError: TestInstallError()
    )
    let viewModel = SettingsViewModel(
        engines: [fakeEngine],
        selectedModelID: recommendedModel.id,
        selectedEngineID: fakeEngine.id,
        generationConfig: .default,
        physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        recommendedModelID: recommendedModel.id,
        client: registry.client
    )
    await viewModel.refresh()

    guard let model = viewModel.models.first else {
        Issue.record("Expected a model row")
        return
    }

    await viewModel.installLocalModel(model, from: URL(fileURLWithPath: "/tmp/InvalidModel"))

    #expect(await registry.importedModelIDs == [])
    #expect(viewModel.errorMessage == "Selected folder is missing MLX model files: tokenizer, weights.")
    #expect(viewModel.models.first?.isDownloaded == false)
    #expect(viewModel.operationModelID == nil)
}

@MainActor
@Test func settingsDeleteRefreshesModelState() async {
    let downloaded = managedModel(recommendedModel, isDownloaded: true, storageBytes: 512, isRecommended: true)
    let deleted = managedModel(recommendedModel, isDownloaded: false, storageBytes: 0, isRecommended: true)
    let registry = FakeModelRegistry(models: [downloaded], modelsAfterDelete: [deleted])
    let viewModel = SettingsViewModel(
        engines: [fakeEngine],
        selectedModelID: recommendedModel.id,
        selectedEngineID: fakeEngine.id,
        generationConfig: .default,
        physicalMemoryBytes: 1,
        recommendedModelID: recommendedModel.id,
        client: registry.client
    )
    await viewModel.refresh()

    guard let model = viewModel.models.first else {
        Issue.record("Expected a model row")
        return
    }

    await viewModel.delete(model)

    #expect(await registry.deletedModelIDs == [recommendedModel.id])
    #expect(viewModel.models.first?.isDownloaded == false)
    #expect(viewModel.models.first?.storageBytes == 0)
}

@Test func settingsFeatureDoesNotImportConcreteInfrastructure() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let files = [
        "Sources/Features/SettingsFeature/SettingsModels.swift",
        "Sources/Features/SettingsFeature/SettingsViewModel.swift",
        "Sources/Features/SettingsFeature/SettingsView.swift",
        "Sources/Features/SettingsFeature/OnboardingView.swift",
    ]
    let forbiddenImports = [
        "import ModelStore",
        "import MLXEngine",
        "import FMEngine",
        "import Persistence",
    ]

    for file in files {
        let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        for forbiddenImport in forbiddenImports {
            #expect(!source.contains(forbiddenImport), "\(file) contains \(forbiddenImport)")
        }
    }
}

private let fakeEngine = SettingsEngineOption(id: "fake", displayName: "Fake", kind: .mlx)

private let recommendedModel = ModelIdentity(
    id: "mlx-community/recommended",
    family: "qwen3",
    quantization: "4bit",
    contextLength: 1_024,
    estimatedMemoryBytes: 1_000
)

private let otherModel = ModelIdentity(
    id: "mlx-community/other",
    family: "qwen3",
    quantization: "4bit",
    contextLength: 1_024,
    estimatedMemoryBytes: 1_000
)

private func managedModel(
    _ model: ModelIdentity,
    isDownloaded: Bool = false,
    storageBytes: Int64 = 0,
    canRunOnDevice: Bool = true,
    isRecommended: Bool
) -> ManagedModel {
    ManagedModel(
        model: model,
        isDownloaded: isDownloaded,
        storageBytes: storageBytes,
        canRunOnDevice: canRunOnDevice,
        isRecommended: isRecommended
    )
}

private actor FakeModelRegistry {
    private var models: [ManagedModel]
    private let modelsAfterDelete: [ManagedModel]?
    private let downloadError: Error?
    private let installError: Error?
    private var deletedIDs: [String] = []
    private var importedIDs: [String] = []
    private var downloadedIDs: [String] = []

    init(
        models: [ManagedModel],
        modelsAfterDelete: [ManagedModel]? = nil,
        downloadError: Error? = nil,
        installError: Error? = nil
    ) {
        self.models = models
        self.modelsAfterDelete = modelsAfterDelete
        self.downloadError = downloadError
        self.installError = installError
    }

    nonisolated var client: ModelManagementClient {
        ModelManagementClient(
            refreshModels: { await self.refresh() },
            downloadModel: { try await self.download($0, progressHandler: $1) },
            installLocalModel: { try await self.install($0, from: $1) },
            deleteModel: { await self.delete($0) }
        )
    }

    var deletedModelIDs: [String] {
        deletedIDs
    }

    var importedModelIDs: [String] {
        importedIDs
    }

    var downloadedModelIDs: [String] {
        downloadedIDs
    }

    private func refresh() -> [ManagedModel] {
        models
    }

    private func download(
        _ model: ModelIdentity,
        progressHandler: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) throws {
        progressHandler(ModelDownloadProgress(completedUnitCount: 25, totalUnitCount: 100))
        if let downloadError {
            throw downloadError
        }

        downloadedIDs.append(model.id)
        models = models.map { row in
            guard row.id == model.id else { return row }
            return ManagedModel(
                model: row.model,
                isDownloaded: true,
                storageBytes: 1,
                canRunOnDevice: row.canRunOnDevice,
                isRecommended: row.isRecommended
            )
        }
        progressHandler(ModelDownloadProgress(completedUnitCount: 100, totalUnitCount: 100))
    }

    private func install(_ model: ModelIdentity, from _: URL) throws {
        if let installError {
            throw installError
        }

        importedIDs.append(model.id)
        models = models.map { row in
            guard row.id == model.id else { return row }
            return ManagedModel(
                model: row.model,
                isDownloaded: true,
                storageBytes: 512,
                canRunOnDevice: row.canRunOnDevice,
                isRecommended: row.isRecommended
            )
        }
    }

    private func delete(_ model: ModelIdentity) {
        deletedIDs.append(model.id)
        if let modelsAfterDelete {
            models = modelsAfterDelete
        }
    }
}

private struct TestInstallError: Error, LocalizedError {
    var errorDescription: String? {
        "Selected folder is missing MLX model files: tokenizer, weights."
    }
}

private enum TestDownloadError: Error, LocalizedError {
    case networkUnavailable

    var errorDescription: String? {
        "Network unavailable."
    }
}
