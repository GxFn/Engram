import EngineKit
import MLXEngine
import ModelStore
import Observation
import SettingsFeature
import SwiftUI

@MainActor
@Observable
public final class AppDependencies {
    private enum DefaultsKey {
        static let activeEngineID = "activeEngineID"
        static let activeModelID = "activeModelID"
        static let temperature = "generation.temperature"
        static let topP = "generation.topP"
        static let maxTokens = "generation.maxTokens"
    }

    public let engines: [any LLMEngine]
    public var activeEngine: any LLMEngine
    public let modelStore: ModelStore
    public var activeModel: ModelIdentity
    public var generationConfig: GenerationConfig

    @ObservationIgnored private let deviceCapability: DeviceCapability
    @ObservationIgnored private let defaults: UserDefaults?

    public init(
        engines: [any LLMEngine] = [MLXEngine()],
        activeEngine: (any LLMEngine)? = nil,
        modelStore: ModelStore = ModelStore(),
        activeModel: ModelIdentity? = nil,
        generationConfig: GenerationConfig? = nil,
        deviceCapability: DeviceCapability = DeviceCapability(),
        defaults: UserDefaults? = .standard
    ) {
        let resolvedEngines = engines.isEmpty ? [MLXEngine()] : engines
        let resolvedModel = activeModel
            ?? Self.storedModel(defaults: defaults)
            ?? deviceCapability.recommendedModel
        let resolvedEngine = activeEngine
            ?? Self.storedEngine(defaults: defaults, engines: resolvedEngines)
            ?? resolvedEngines[0]

        self.engines = resolvedEngines
        self.activeEngine = resolvedEngine
        self.modelStore = modelStore
        self.activeModel = resolvedModel
        self.generationConfig = GenerationConfigBounds.clamped(
            generationConfig
                ?? Self.storedGenerationConfig(defaults: defaults)
                ?? .default
        )
        self.deviceCapability = deviceCapability
        self.defaults = defaults
    }

    public func selectEngine(id: String) {
        guard let engine = engines.first(where: { $0.descriptor.id == id }) else {
            return
        }

        activeEngine = engine
        defaults?.set(id, forKey: DefaultsKey.activeEngineID)
    }

    public func selectModel(_ model: ModelIdentity) {
        activeModel = model
        defaults?.set(model.id, forKey: DefaultsKey.activeModelID)
    }

    public func updateGenerationConfig(_ config: GenerationConfig) {
        generationConfig = GenerationConfigBounds.clamped(config)
        persistGenerationConfig()
    }

    public func makeSettingsViewModel() -> SettingsViewModel {
        let store = modelStore
        let capability = deviceCapability
        let launchLineup = ModelCatalog.launchLineup

        let client = ModelManagementClient(
            refreshModels: {
                let downloadedModels = try await store.downloadedModels()
                let allModels = Self.uniqueModels(launchLineup + downloadedModels)

                var rows: [ManagedModel] = []
                for model in allModels {
                    let isDownloaded = try await store.isDownloaded(model)
                    let storageBytes = try await store.storageBytes(for: model)
                    rows.append(ManagedModel(
                        model: model,
                        isDownloaded: isDownloaded,
                        storageBytes: storageBytes,
                        canRunOnDevice: capability.canRun(model),
                        isRecommended: model.id == capability.recommendedModel.id
                    ))
                }

                return rows
            },
            downloadModel: { model in
                try await store.download(model)
            },
            deleteModel: { model in
                try await store.delete(model)
            }
        )

        return SettingsViewModel(
            engines: engines.map {
                SettingsEngineOption(
                    id: $0.descriptor.id,
                    displayName: $0.descriptor.displayName,
                    kind: $0.descriptor.kind
                )
            },
            selectedModelID: activeModel.id,
            selectedEngineID: activeEngine.descriptor.id,
            generationConfig: generationConfig,
            physicalMemoryBytes: deviceCapability.physicalMemoryBytes,
            recommendedModelID: deviceCapability.recommendedModel.id,
            client: client,
            applyActiveModel: { [weak self] model in
                self?.selectModel(model)
            },
            applyActiveEngine: { [weak self] engineID in
                self?.selectEngine(id: engineID)
            },
            applyGenerationConfig: { [weak self] config in
                self?.updateGenerationConfig(config)
            }
        )
    }

    private func persistGenerationConfig() {
        defaults?.set(generationConfig.temperature, forKey: DefaultsKey.temperature)
        defaults?.set(generationConfig.topP, forKey: DefaultsKey.topP)
        defaults?.set(generationConfig.maxTokens, forKey: DefaultsKey.maxTokens)
    }

    private static func storedEngine(
        defaults: UserDefaults?,
        engines: [any LLMEngine]
    ) -> (any LLMEngine)? {
        guard let id = defaults?.string(forKey: DefaultsKey.activeEngineID) else {
            return nil
        }

        return engines.first { $0.descriptor.id == id }
    }

    private static func storedModel(defaults: UserDefaults?) -> ModelIdentity? {
        guard let id = defaults?.string(forKey: DefaultsKey.activeModelID) else {
            return nil
        }

        return ModelCatalog.launchLineup.first { $0.id == id }
    }

    private static func storedGenerationConfig(defaults: UserDefaults?) -> GenerationConfig? {
        guard let defaults,
              defaults.object(forKey: DefaultsKey.temperature) != nil,
              defaults.object(forKey: DefaultsKey.topP) != nil,
              defaults.object(forKey: DefaultsKey.maxTokens) != nil
        else {
            return nil
        }

        return GenerationConfigBounds.clamped(GenerationConfig(
            temperature: defaults.double(forKey: DefaultsKey.temperature),
            topP: defaults.double(forKey: DefaultsKey.topP),
            maxTokens: defaults.integer(forKey: DefaultsKey.maxTokens)
        ))
    }

    private nonisolated static func uniqueModels(_ models: [ModelIdentity]) -> [ModelIdentity] {
        var seenIDs = Set<String>()
        var uniqueModels: [ModelIdentity] = []

        for model in models where !seenIDs.contains(model.id) {
            seenIDs.insert(model.id)
            uniqueModels.append(model)
        }

        return uniqueModels
    }
}

private struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies? = nil
}

public extension EnvironmentValues {
    var deps: AppDependencies? {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
}
