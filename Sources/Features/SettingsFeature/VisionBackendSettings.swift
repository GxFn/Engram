import Foundation

public enum VisionBackendKind: String, Sendable, CaseIterable, Codable {
    case onDevice
    case cloud

    public var displayName: String {
        switch self {
        case .onDevice:
            "本地"
        case .cloud:
            "云端"
        }
    }
}

/// User-facing vision-backend settings. The API key itself is never surfaced back to the UI
/// (`hasCloudKey` only reports whether one is stored), so it stays in the Keychain.
public struct VisionBackendSettings: Sendable, Equatable {
    public var kind: VisionBackendKind
    public var cloudBaseURL: String
    public var cloudModel: String      // vision model id
    public var cloudTextModel: String  // text/LLM model id
    public var hasCloudKey: Bool

    public init(
        kind: VisionBackendKind = .onDevice,
        cloudBaseURL: String = "",
        cloudModel: String = "",
        cloudTextModel: String = "",
        hasCloudKey: Bool = false
    ) {
        self.kind = kind
        self.cloudBaseURL = cloudBaseURL
        self.cloudModel = cloudModel
        self.cloudTextModel = cloudTextModel
        self.hasCloudKey = hasCloudKey
    }
}

/// Load/save closures supplied by the assembly layer (it owns UserDefaults + Keychain).
/// `save` takes the settings plus an optional new key; nil means "leave the stored key unchanged".
public struct VisionBackendClient: Sendable {
    public let load: @Sendable () -> VisionBackendSettings
    public let save: @Sendable (VisionBackendSettings, String?) -> Void

    public init(
        load: @escaping @Sendable () -> VisionBackendSettings,
        save: @escaping @Sendable (VisionBackendSettings, String?) -> Void
    ) {
        self.load = load
        self.save = save
    }

    public static let empty = VisionBackendClient(load: { VisionBackendSettings() }, save: { _, _ in })
}
