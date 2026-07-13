import Foundation

public enum AnalysisStage: String, Codable, Hashable, Sendable, CaseIterable {
    case assetProbe
    case shotDetection
    case keyframes
    case transcription
    case ocr
    case evidenceAssembly
    case shotUnderstanding
    case cloudVideo
    case timelineAlignment
    case synthesis
    case quality
    case indexing
    case completed
}

public enum AnalysisRunStatus: String, Codable, Hashable, Sendable {
    case running
    case partial
    case completed
    case failed
    case cancelled
}

public struct ArtifactCheckpoint: Codable, Hashable, Sendable {
    public let stage: AnalysisStage
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int
    public let completedAt: Date

    public init(
        stage: AnalysisStage,
        relativePath: String,
        sha256: String,
        byteCount: Int,
        completedAt: Date
    ) {
        self.stage = stage
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.completedAt = completedAt
    }
}

/// Durable, provider-neutral accounting for one cloud execution. Optional values mean the
/// selected provider did not report that dimension; they must not be replaced with invented 0s.
public struct AnalysisCloudTelemetry: Codable, Hashable, Sendable {
    public let requestedMode: String
    public let effectiveMode: String
    public let mediaBytesUploaded: Int64?
    public let requestBytes: Int64?
    public let requestCount: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let mediaMilliseconds: Int64?
    public let estimatedUSD: Decimal?
    public let sanitizedError: String?
    public let refinementShotIDs: [String]

    public init(
        requestedMode: String,
        effectiveMode: String,
        mediaBytesUploaded: Int64? = nil,
        requestBytes: Int64? = nil,
        requestCount: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        mediaMilliseconds: Int64? = nil,
        estimatedUSD: Decimal? = nil,
        sanitizedError: String? = nil,
        refinementShotIDs: [String] = []
    ) {
        self.requestedMode = requestedMode
        self.effectiveMode = effectiveMode
        self.mediaBytesUploaded = mediaBytesUploaded
        self.requestBytes = requestBytes
        self.requestCount = requestCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.mediaMilliseconds = mediaMilliseconds
        self.estimatedUSD = estimatedUSD
        self.sanitizedError = sanitizedError
        self.refinementShotIDs = refinementShotIDs
    }
}

public struct AnalysisRun: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let clipID: String
    public let fingerprint: SourceFingerprint
    public let schemaVersion: Int
    public let pipelineVersion: String
    public let status: AnalysisRunStatus
    public let currentStage: AnalysisStage
    public let completedStages: [AnalysisStage]
    public let checkpoints: [ArtifactCheckpoint]
    public let startedAt: Date
    public let updatedAt: Date
    public let retryCount: Int
    public let mediaBytesUploaded: Int64
    public let degradationNotes: [String]
    public let cloudTelemetry: AnalysisCloudTelemetry?

    public init(
        id: String,
        clipID: String,
        fingerprint: SourceFingerprint,
        schemaVersion: Int,
        pipelineVersion: String,
        status: AnalysisRunStatus,
        currentStage: AnalysisStage,
        completedStages: [AnalysisStage],
        checkpoints: [ArtifactCheckpoint],
        startedAt: Date,
        updatedAt: Date,
        retryCount: Int = 0,
        mediaBytesUploaded: Int64 = 0,
        degradationNotes: [String] = [],
        cloudTelemetry: AnalysisCloudTelemetry? = nil
    ) {
        self.id = id
        self.clipID = clipID
        self.fingerprint = fingerprint
        self.schemaVersion = schemaVersion
        self.pipelineVersion = pipelineVersion
        self.status = status
        self.currentStage = currentStage
        self.completedStages = completedStages
        self.checkpoints = checkpoints
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.retryCount = retryCount
        self.mediaBytesUploaded = mediaBytesUploaded
        self.degradationNotes = degradationNotes
        self.cloudTelemetry = cloudTelemetry
    }
}
