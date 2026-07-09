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
    public private(set) var downloadProgress: ModelDownloadProgress?
    public private(set) var visionBackend: VisionBackendSettings
    public var errorMessage: String?

    public let engines: [SettingsEngineOption]
    public let physicalMemoryBytes: Int64
    public let recommendedModelID: String

    @ObservationIgnored private let client: ModelManagementClient
    @ObservationIgnored private let visionBackendClient: VisionBackendClient
    @ObservationIgnored private let applyActiveModel: (ModelIdentity) -> Void
    @ObservationIgnored private let applyActiveEngine: (String) -> Void
    @ObservationIgnored private let applyGenerationConfig: (GenerationConfig) -> Void
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    public init(
        engines: [SettingsEngineOption],
        models: [ManagedModel] = [],
        selectedModelID: String,
        selectedEngineID: String,
        generationConfig: GenerationConfig,
        physicalMemoryBytes: Int64,
        recommendedModelID: String,
        client: ModelManagementClient = .empty,
        visionBackendClient: VisionBackendClient = .empty,
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
        self.visionBackendClient = visionBackendClient
        self.visionBackend = visionBackendClient.load()
        self.applyActiveModel = applyActiveModel
        self.applyActiveEngine = applyActiveEngine
        self.applyGenerationConfig = applyGenerationConfig
        self.isRefreshing = false
    }

    // MARK: - Vision backend (on-device Qwen3-VL ↔ cloud VLM)

    public func selectVisionBackend(_ kind: VisionBackendKind) {
        visionBackend.kind = kind
        visionBackendClient.save(visionBackend, nil)
    }

    public func setCloudBaseURL(_ value: String) {
        visionBackend.cloudBaseURL = value
        visionBackendClient.save(visionBackend, nil)
    }

    public func setCloudModel(_ value: String) {
        visionBackend.cloudModel = value
        visionBackendClient.save(visionBackend, nil)
    }

    public func setCloudTextModel(_ value: String) {
        visionBackend.cloudTextModel = value
        visionBackendClient.save(visionBackend, nil)
    }

    /// True in 云端 mode when any required field is missing. Cloud routing is all-or-nothing (a
    /// partial config must not split text/vision across backends), so until complete the whole
    /// pipeline runs on-device — Settings must say so instead of silently downgrading.
    public var cloudConfigIncomplete: Bool {
        visionBackend.kind == .cloud && (
            visionBackend.cloudBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
                || visionBackend.cloudModel.trimmingCharacters(in: .whitespaces).isEmpty
                || visionBackend.cloudTextModel.trimmingCharacters(in: .whitespaces).isEmpty
                || !visionBackend.hasCloudKey
        )
    }

    /// Stores the API key in the Keychain (via the client) and only tracks whether one exists.
    public func setCloudAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        visionBackend.hasCloudKey = !trimmed.isEmpty
        visionBackendClient.save(visionBackend, trimmed)
    }

    public var selectedModel: ManagedModel? {
        models.first { $0.id == selectedModelID }
    }

    public var recommendedModel: ManagedModel? {
        models.first { $0.id == recommendedModelID }
    }

    /// Only the models this device can actually run — Settings hides the ones that don't fit so the
    /// list reflects what's usable here, not the whole catalog.
    public var runnableModels: [ManagedModel] {
        models.filter(\.canRunOnDevice)
    }

    /// True when at least one vision model fits this device. When false, on-device AI is text-only,
    /// so 画面理解 (拆解) needs the cloud backend — Settings surfaces that recommendation.
    public var canRunVisionLocally: Bool {
        models.contains { $0.canRunOnDevice && $0.purpose == .vision }
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

            // Only auto-pick a default on-device model in 本地 mode. In 云端 mode the active model is
            // the cloud identity; auto-selecting the recommended local model here would clobber it —
            // the bug where opening Settings then returning to 问答 flipped 云端 AI to Qwen3-1.7B.
            if visionBackend.kind == .onDevice, selectedModel == nil, let recommendedModel {
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

        let modelID = model.id
        operationModelID = model.id
        errorMessage = nil
        downloadProgress = ModelDownloadProgress(completedUnitCount: 0, totalUnitCount: nil)
        defer { operationModelID = nil }

        do {
            try await client.downloadModel(model.model) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.operationModelID == modelID else {
                        return
                    }

                    self.downloadProgress = progress
                }
            }
            await refresh()
            if models.first(where: { $0.id == model.id })?.isDownloaded == true {
                selectModel(model.model)
            }
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    public func beginDownload(_ model: ManagedModel) {
        guard operationTask == nil else {
            return
        }

        operationTask = Task { [weak self] in
            await self?.download(model)
            await MainActor.run { [weak self] in
                self?.operationTask = nil
            }
        }
    }

    public func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
    }

    public func installLocalModel(_ model: ManagedModel, from sourceURL: URL) async {
        guard operationModelID == nil else {
            return
        }

        operationModelID = model.id
        errorMessage = nil
        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
            operationModelID = nil
        }

        do {
            try await client.installLocalModel(model.model, sourceURL)
            await refresh()
            if models.first(where: { $0.id == model.id })?.isDownloaded == true {
                selectModel(model.model)
            }
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

    public static func formatProgress(_ progress: ModelDownloadProgress?) -> String {
        guard let progress else {
            return "Preparing download"
        }

        let completed = formatBytes(progress.completedUnitCount)
        if let total = progress.totalUnitCount, total > 0, let fraction = progress.fractionCompleted {
            let percent = Int((fraction * 100).rounded(.down))
            return "\(percent)% · \(completed) of \(formatBytes(total))"
        }

        if progress.completedUnitCount > 0 {
            return "\(completed) downloaded"
        }

        return "Preparing download"
    }

    public static func userFacingMessage(for error: Error) -> String {
        if let engineError = error as? EngineError {
            switch engineError {
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

        if error is CancellationError {
            return "Stopped."
        }

        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return "Model operation failed."
    }
}
