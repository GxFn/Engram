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

/// What a local model is for — surfaced in Settings so users see each model's role, and so the app
/// can tell when a device can only do text (no vision model fits → recommend the cloud backend for
/// 画面理解/拆解).
public enum ModelPurpose: Sendable, Hashable {
    case language   // text LLM — 问答 / 剧本文本
    case vision     // VLM — 视频画面理解 (拆解)
    case retrieval  // embedding — 内容检索

    public var displayName: String {
        switch self {
        case .language: return "语言"
        case .vision: return "视觉"
        case .retrieval: return "检索"
        }
    }

    /// One-line description of what this model powers in the app.
    public var usage: String {
        switch self {
        case .language: return "问答与剧本文本"
        case .vision: return "视频画面理解"
        case .retrieval: return "内容检索"
        }
    }
}

extension ManagedModel {
    /// Classifies the model by its family so the UI can show its role and detect a vision-capable
    /// device. Families come from `ModelCatalog` (qwen3 / qwen3-vl / qwen3-embedding).
    public var purpose: ModelPurpose {
        let family = model.family.lowercased()
        if family.contains("vl") { return .vision }
        if family.contains("embedding") { return .retrieval }
        return .language
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
