import EngineKit
import Foundation
import Observation

@MainActor
@Observable
public final class SettingsViewModel {
    public private(set) var models: [ManagedModel]
    public private(set) var selectedModelID: String
    public private(set) var selectedEngineID: String
    public private(set) var generationConfig: GenerationConfig
    public private(set) var isRefreshing: Bool
    public private(set) var operationModelID: String?
    public var errorMessage: String?

    public let engines: [SettingsEngineOption]
    public let physicalMemoryBytes: Int64
    public let recommendedModelID: String

    @ObservationIgnored private let client: ModelManagementClient
    @ObservationIgnored private let applyActiveModel: (ModelIdentity) -> Void
    @ObservationIgnored private let applyActiveEngine: (String) -> Void
    @ObservationIgnored private let applyGenerationConfig: (GenerationConfig) -> Void

    public init(
        engines: [SettingsEngineOption],
        models: [ManagedModel] = [],
        selectedModelID: String,
        selectedEngineID: String,
        generationConfig: GenerationConfig,
        physicalMemoryBytes: Int64,
        recommendedModelID: String,
        client: ModelManagementClient = .empty,
        applyActiveModel: @escaping (ModelIdentity) -> Void = { _ in },
        applyActiveEngine: @escaping (String) -> Void = { _ in },
        applyGenerationConfig: @escaping (GenerationConfig) -> Void = { _ in }
    ) {
        self.engines = engines
        self.models = models
        self.selectedModelID = selectedModelID
        self.selectedEngineID = selectedEngineID
        self.generationConfig = GenerationConfigBounds.clamped(generationConfig)
        self.physicalMemoryBytes = physicalMemoryBytes
        self.recommendedModelID = recommendedModelID
        self.client = client
        self.applyActiveModel = applyActiveModel
        self.applyActiveEngine = applyActiveEngine
        self.applyGenerationConfig = applyGenerationConfig
        self.isRefreshing = false
    }

    public var selectedModel: ManagedModel? {
        models.first { $0.id == selectedModelID }
    }

    public var recommendedModel: ManagedModel? {
        models.first { $0.id == recommendedModelID }
    }

    public var memorySummary: String {
        Self.formatBytes(physicalMemoryBytes)
    }

    public func refresh() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            models = try await client.refreshModels().sorted {
                if $0.isRecommended != $1.isRecommended {
                    return $0.isRecommended
                }
                return $0.id < $1.id
            }

            if selectedModel == nil, let recommendedModel {
                selectModel(recommendedModel.model)
            }
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    public func selectModel(_ model: ModelIdentity) {
        selectedModelID = model.id
        applyActiveModel(model)
    }

    public func selectEngine(id: String) {
        guard engines.contains(where: { $0.id == id }) else {
            return
        }

        selectedEngineID = id
        applyActiveEngine(id)
    }

    public func download(_ model: ManagedModel) async {
        guard operationModelID == nil else {
            return
        }

        operationModelID = model.id
        errorMessage = nil
        defer { operationModelID = nil }

        do {
            try await client.downloadModel(model.model)
            await refresh()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    public func delete(_ model: ManagedModel) async {
        guard operationModelID == nil else {
            return
        }

        operationModelID = model.id
        errorMessage = nil
        defer { operationModelID = nil }

        do {
            try await client.deleteModel(model.model)
            await refresh()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    public func setTemperature(_ value: Double) {
        updateConfig { $0.temperature = value }
    }

    public func setTopP(_ value: Double) {
        updateConfig { $0.topP = value }
    }

    public func setMaxTokens(_ value: Int) {
        updateConfig { $0.maxTokens = value }
    }

    private func updateConfig(_ edit: (inout GenerationConfig) -> Void) {
        var updated = generationConfig
        edit(&updated)
        generationConfig = GenerationConfigBounds.clamped(updated)
        applyGenerationConfig(generationConfig)
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let safeBytes = max(0, bytes)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = safeBytes >= 1_073_741_824 ? [.useGB] : [.useMB]
        return formatter.string(fromByteCount: safeBytes)
    }

    public static func userFacingMessage(for error: Error) -> String {
        if let engineError = error as? EngineError {
            switch engineError {
            case .notImplemented(let message) where message.contains("remote model download deferred"):
                return "Remote model download is not wired yet. Add a verified local model in Settings."
            case .notImplemented:
                return "Model management is not ready yet."
            case .modelNotLoaded:
                return "Model is not loaded."
            case .outOfMemory:
                return "This device does not have enough memory for that model."
            case .cancelled:
                return "Stopped."
            }
        }

        return "Model operation failed."
    }
}
