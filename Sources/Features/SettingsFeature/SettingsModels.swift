import EngineKit
import Foundation

public struct SettingsEngineOption: Identifiable, Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let kind: EngineKind

    public init(id: String, displayName: String, kind: EngineKind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

public struct ManagedModel: Identifiable, Sendable, Hashable {
    public let model: ModelIdentity
    public let isDownloaded: Bool
    public let storageBytes: Int64
    public let canRunOnDevice: Bool
    public let isRecommended: Bool

    public var id: String { model.id }

    public var displayName: String {
        model.id.split(separator: "/").last.map(String.init) ?? model.id
    }

    public init(
        model: ModelIdentity,
        isDownloaded: Bool,
        storageBytes: Int64,
        canRunOnDevice: Bool,
        isRecommended: Bool
    ) {
        self.model = model
        self.isDownloaded = isDownloaded
        self.storageBytes = storageBytes
        self.canRunOnDevice = canRunOnDevice
        self.isRecommended = isRecommended
    }
}

public struct ModelDownloadProgress: Sendable, Equatable {
    public let completedUnitCount: Int64
    public let totalUnitCount: Int64?
    public let fractionCompleted: Double?

    public init(completedUnitCount: Int64, totalUnitCount: Int64?) {
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount

        guard let totalUnitCount, totalUnitCount > 0 else {
            self.fractionCompleted = nil
            return
        }

        self.fractionCompleted = min(1, max(0, Double(completedUnitCount) / Double(totalUnitCount)))
    }
}

public struct ModelManagementClient: Sendable {
    public var refreshModels: @Sendable () async throws -> [ManagedModel]
    public var downloadModel: @Sendable (
        ModelIdentity,
        @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> Void
    public var installLocalModel: @Sendable (ModelIdentity, URL) async throws -> Void
    public var deleteModel: @Sendable (ModelIdentity) async throws -> Void

    public init(
        refreshModels: @escaping @Sendable () async throws -> [ManagedModel],
        downloadModel: @escaping @Sendable (
            ModelIdentity,
            @escaping @Sendable (ModelDownloadProgress) -> Void
        ) async throws -> Void,
        installLocalModel: @escaping @Sendable (ModelIdentity, URL) async throws -> Void,
        deleteModel: @escaping @Sendable (ModelIdentity) async throws -> Void
    ) {
        self.refreshModels = refreshModels
        self.downloadModel = downloadModel
        self.installLocalModel = installLocalModel
        self.deleteModel = deleteModel
    }

    public static let empty = ModelManagementClient(
        refreshModels: { [] },
        downloadModel: { _, _ in },
        installLocalModel: { _, _ in },
        deleteModel: { _ in }
    )
}

public enum GenerationConfigBounds {
    public static let temperature = 0.0...2.0
    public static let topP = 0.05...1.0
    public static let maxTokens = 16...4_096

    public static func clamped(_ config: GenerationConfig) -> GenerationConfig {
        GenerationConfig(
            temperature: min(max(config.temperature, temperature.lowerBound), temperature.upperBound),
            topP: min(max(config.topP, topP.lowerBound), topP.upperBound),
            maxTokens: min(max(config.maxTokens, maxTokens.lowerBound), maxTokens.upperBound)
        )
    }
}
