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
        degradationNotes: [String] = []
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
    }
}
