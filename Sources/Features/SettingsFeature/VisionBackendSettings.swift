import Foundation

public enum VisionBackendKind: String, Sendable, CaseIterable, Codable {
    // Cloud first so it reads as the primary option (leftmost) in the segmented control.
    case cloud
    case onDevice

    public var displayName: String {
        switch self {
        case .onDevice:
            "本地"
        case .cloud:
            "云端"
        }
    }
}

public enum CloudVideoAnalysisMode: String, Sendable, CaseIterable, Codable {
    case standard
    case deep

    public var displayName: String { self == .deep ? "云端深度" : "云端标准" }
}

public enum CloudAnalysisRequestedMode: String, Sendable, CaseIterable, Codable {
    case local
    case arkStandard
    case lasDeep
    case hybridMaximum

    public var displayName: String {
        switch self {
        case .local: "Local"
        case .arkStandard: "Ark Standard"
        case .lasDeep: "LAS Deep"
        case .hybridMaximum: "LAS + Ark Refine"
        }
    }
}

public struct ArkBackendSettings: Sendable, Equatable {
    public var baseURL: String
    public var textModelID: String
    public var frameModelID: String
    public var hasAPIKey: Bool

    public init(
        baseURL: String = "https://ark.cn-beijing.volces.com/api/v3",
        textModelID: String = "",
        frameModelID: String = "",
        hasAPIKey: Bool = false
    ) {
        self.baseURL = baseURL
        self.textModelID = textModelID
        self.frameModelID = frameModelID
        self.hasAPIKey = hasAPIKey
    }

    public var isConfigured: Bool {
        URL(string: baseURL)?.scheme == "https"
            && !textModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !frameModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasAPIKey
    }
}

public enum LASServiceRegion: String, Sendable, CaseIterable, Codable {
    case cnBeijing = "cn-beijing"

    public var operatorBaseURL: URL {
        switch self {
        case .cnBeijing: URL(string: "https://operator.las.cn-beijing.volces.com")!
        }
    }

    public var tosEndpoint: URL {
        switch self {
        case .cnBeijing: URL(string: "https://tos-cn-beijing.volces.com")!
        }
    }
}

public enum LASConfigurationRole: String, Sendable, CaseIterable, Codable, Comparable {
    case videoStoryboard
    case videoFineUnderstanding
    case scriptGeneration
    case enhancedASR
    case mediaStaging

    public static func < (lhs: Self, rhs: Self) -> Bool {
        guard let left = allCases.firstIndex(of: lhs), let right = allCases.firstIndex(of: rhs) else {
            return lhs.rawValue < rhs.rawValue
        }
        return left < right
    }

    public var displayName: String {
        switch self {
        case .videoStoryboard: "Video storyboard"
        case .videoFineUnderstanding: "Video fine understanding"
        case .scriptGeneration: "Short-drama/movie script generation"
        case .enhancedASR: "Doubao enhanced ASR"
        case .mediaStaging: "TOS media staging"
        }
    }
}

public struct LASBackendSettings: Sendable, Equatable {
    public var isEnabled: Bool
    public var region: LASServiceRegion
    public var videoStoryboardOperatorID: String
    public var videoFineUnderstandingOperatorID: String
    public var scriptGenerationOperatorID: String
    public var enhancedASROperatorID: String
    public var hasAPIKey: Bool

    public init(
        isEnabled: Bool = false,
        region: LASServiceRegion = .cnBeijing,
        videoStoryboardOperatorID: String = "",
        videoFineUnderstandingOperatorID: String = "",
        scriptGenerationOperatorID: String = "",
        enhancedASROperatorID: String = "",
        hasAPIKey: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.region = region
        self.videoStoryboardOperatorID = videoStoryboardOperatorID
        self.videoFineUnderstandingOperatorID = videoFineUnderstandingOperatorID
        self.scriptGenerationOperatorID = scriptGenerationOperatorID
        self.enhancedASROperatorID = enhancedASROperatorID
        self.hasAPIKey = hasAPIKey
    }

    public var operatorBaseURL: URL { region.operatorBaseURL }
    public var operatorProcessURL: URL { operatorBaseURL.appendingPathComponent("api/v1/process") }
}

public struct TOSStagingSettings: Sendable, Equatable {
    public var bucket: String
    public var objectPrefix: String
    public var credentialReferenceID: String
    public var temporaryCredentialExpiresAt: Date?
    public var hasTemporaryCredentials: Bool
    public var maximumUploadMegabytes: Int

    public init(
        bucket: String = "",
        objectPrefix: String = "engram/",
        credentialReferenceID: String = "",
        temporaryCredentialExpiresAt: Date? = nil,
        hasTemporaryCredentials: Bool = false,
        maximumUploadMegabytes: Int = 2_000
    ) {
        self.bucket = bucket
        self.objectPrefix = objectPrefix
        self.credentialReferenceID = credentialReferenceID
        self.temporaryCredentialExpiresAt = temporaryCredentialExpiresAt
        self.hasTemporaryCredentials = hasTemporaryCredentials
        self.maximumUploadMegabytes = max(1, maximumUploadMegabytes)
    }

    public var endpoint: URL { LASServiceRegion.cnBeijing.tosEndpoint }

    public var isConfigured: Bool {
        hasTemporaryCredentials
            && !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && objectPrefix.hasPrefix("engram/")
            && !credentialReferenceID.isEmpty
    }
}

/// User-facing vision-backend settings. The API key itself is never surfaced back to the UI
/// (`hasCloudKey` only reports whether one is stored), so it stays in the Keychain.
public struct VisionBackendSettings: Sendable, Equatable {
    public var requestedMode: CloudAnalysisRequestedMode
    public var ark: ArkBackendSettings
    public var las: LASBackendSettings
    public var staging: TOSStagingSettings

    public init(
        requestedMode: CloudAnalysisRequestedMode = .local,
        ark: ArkBackendSettings = ArkBackendSettings(),
        las: LASBackendSettings = LASBackendSettings(),
        staging: TOSStagingSettings = TOSStagingSettings()
    ) {
        self.requestedMode = requestedMode
        self.ark = ark
        self.las = las
        self.staging = staging
    }

    public init(
        kind: VisionBackendKind = .onDevice,
        cloudBaseURL: String = "",
        cloudModel: String = "",
        cloudTextModel: String = "",
        hasCloudKey: Bool = false,
        cloudVideoMode: CloudVideoAnalysisMode = .standard,
        allowsFullVideoUpload: Bool = false,
        maximumUploadMegabytes: Int = 200
    ) {
        requestedMode = if kind == .onDevice {
            .local
        } else if cloudVideoMode == .deep {
            .lasDeep
        } else {
            .arkStandard
        }
        ark = ArkBackendSettings(
            baseURL: cloudBaseURL,
            textModelID: cloudTextModel,
            frameModelID: cloudModel,
            hasAPIKey: hasCloudKey
        )
        las = LASBackendSettings()
        staging = TOSStagingSettings(maximumUploadMegabytes: maximumUploadMegabytes)
    }

    public var kind: VisionBackendKind {
        get { requestedMode == .local ? .onDevice : .cloud }
        set {
            if newValue == .onDevice { requestedMode = .local }
            else if requestedMode == .local { requestedMode = .arkStandard }
        }
    }

    public var cloudBaseURL: String {
        get { ark.baseURL }
        set { ark.baseURL = newValue }
    }

    public var cloudModel: String {
        get { ark.frameModelID }
        set { ark.frameModelID = newValue }
    }

    public var cloudTextModel: String {
        get { ark.textModelID }
        set { ark.textModelID = newValue }
    }

    public var hasCloudKey: Bool {
        get { ark.hasAPIKey }
        set { ark.hasAPIKey = newValue }
    }

    public var cloudVideoMode: CloudVideoAnalysisMode {
        get { requestedMode == .lasDeep || requestedMode == .hybridMaximum ? .deep : .standard }
        set { requestedMode = newValue == .deep ? .lasDeep : .arkStandard }
    }

    /// Legacy source compatibility only. Upload authorization is now a run/asset/plan receipt.
    public var allowsFullVideoUpload: Bool {
        get { false }
        set { /* A reusable settings flag is intentionally ignored. */ }
    }

    public var maximumUploadMegabytes: Int {
        get { staging.maximumUploadMegabytes }
        set { staging.maximumUploadMegabytes = max(1, newValue) }
    }

    public var requiresRunScopedConsent: Bool {
        requestedMode == .lasDeep || requestedMode == .hybridMaximum
    }

    public var missingLASConfigurationRoles: [LASConfigurationRole] {
        guard las.isEnabled else { return LASConfigurationRole.allCases }
        var roles: [LASConfigurationRole] = []
        func missing(_ value: String, _ role: LASConfigurationRole) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { roles.append(role) }
        }
        if !las.hasAPIKey {
            roles += [.videoStoryboard, .videoFineUnderstanding, .scriptGeneration, .enhancedASR]
        } else {
            missing(las.videoStoryboardOperatorID, .videoStoryboard)
            missing(las.videoFineUnderstandingOperatorID, .videoFineUnderstanding)
            missing(las.scriptGenerationOperatorID, .scriptGeneration)
            missing(las.enhancedASROperatorID, .enhancedASR)
        }
        if !staging.isConfigured { roles.append(.mediaStaging) }
        return Array(Set(roles)).sorted()
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
