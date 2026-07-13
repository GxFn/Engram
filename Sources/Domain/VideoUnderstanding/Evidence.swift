import Foundation

public struct EvidenceID: Codable, Hashable, Sendable, RawRepresentable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: EvidenceID, rhs: EvidenceID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum EvidenceKind: String, Codable, Hashable, Sendable {
    case transcript
    case ocr
    case frame
    case audio
    case detector
    case user
    case cloudTimeline
}

public enum EvidenceSource: String, Codable, Hashable, Sendable {
    case deterministic
    case onDeviceModel
    case cloudModel
    case user
}

public struct EvidenceRef: Codable, Hashable, Sendable, Identifiable {
    public let id: EvidenceID
    public let kind: EvidenceKind
    public let timeRange: MediaTimeRange
    public let frameRange: FrameRange?
    public let payloadRef: String
    public let source: EvidenceSource
    public let confidence: Double
    public let modelVersion: String?
    public let createdAt: Date
    public let rawText: String?
    public let correctedText: String?

    public init(
        id: EvidenceID,
        kind: EvidenceKind,
        timeRange: MediaTimeRange,
        frameRange: FrameRange?,
        payloadRef: String,
        source: EvidenceSource,
        confidence: Double,
        modelVersion: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        rawText: String? = nil,
        correctedText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timeRange = timeRange
        self.frameRange = frameRange
        self.payloadRef = payloadRef
        self.source = source
        self.confidence = confidence
        self.modelVersion = modelVersion
        self.createdAt = createdAt
        self.rawText = rawText
        self.correctedText = correctedText
    }
}
