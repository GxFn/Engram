import Foundation

public struct SourceFingerprint: Codable, Hashable, Sendable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

public struct VideoAssetDescriptor: Codable, Hashable, Sendable {
    public let sourceID: String
    public let durationSeconds: Double
    public let nominalFrameRate: Double
    public let frameCount: Int?
    public let width: Int
    public let height: Int
    public let timescale: Int32
    public let codec: String?
    public let hasAudio: Bool
    public let fileSizeBytes: Int64
    public let fingerprint: SourceFingerprint

    public init(
        sourceID: String,
        durationSeconds: Double,
        nominalFrameRate: Double,
        frameCount: Int?,
        width: Int,
        height: Int,
        timescale: Int32,
        codec: String?,
        hasAudio: Bool,
        fileSizeBytes: Int64,
        fingerprint: SourceFingerprint
    ) {
        self.sourceID = sourceID
        self.durationSeconds = durationSeconds
        self.nominalFrameRate = nominalFrameRate
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.timescale = timescale
        self.codec = codec
        self.hasAudio = hasAudio
        self.fileSizeBytes = fileSizeBytes
        self.fingerprint = fingerprint
    }
}

public struct MediaTimeRange: Codable, Hashable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public var durationSeconds: Double { endSeconds - startSeconds }

    public func contains(_ seconds: Double) -> Bool {
        seconds >= startSeconds && seconds < endSeconds
    }
}

public struct FrameRange: Codable, Hashable, Sendable {
    public let startFrame: Int
    public let endFrameExclusive: Int

    public init(startFrame: Int, endFrameExclusive: Int) {
        self.startFrame = startFrame
        self.endFrameExclusive = endFrameExclusive
    }

    public var frameCount: Int { endFrameExclusive - startFrame }
}

public struct ShotID: Codable, Hashable, Sendable, RawRepresentable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: ShotID, rhs: ShotID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ShotTransition: String, Codable, Hashable, Sendable {
    case start
    case end
    case cut
    case fade
    case dissolve
    case unknown
}

public struct ShotSegment: Codable, Hashable, Sendable, Identifiable {
    public let id: ShotID
    public let timeRange: MediaTimeRange
    public let frameRange: FrameRange
    public let transitionIn: ShotTransition
    public let transitionOut: ShotTransition
    public let boundaryConfidence: Double
    public let detectorEvidenceIDs: [String]
    public let representativeFrameRefs: [String]

    public init(
        id: ShotID,
        timeRange: MediaTimeRange,
        frameRange: FrameRange,
        transitionIn: ShotTransition,
        transitionOut: ShotTransition,
        boundaryConfidence: Double,
        detectorEvidenceIDs: [String],
        representativeFrameRefs: [String] = []
    ) {
        self.id = id
        self.timeRange = timeRange
        self.frameRange = frameRange
        self.transitionIn = transitionIn
        self.transitionOut = transitionOut
        self.boundaryConfidence = boundaryConfidence
        self.detectorEvidenceIDs = detectorEvidenceIDs
        self.representativeFrameRefs = representativeFrameRefs
    }
}

public enum ShotGraphValidationError: Error, Codable, Hashable, Sendable {
    case invalidAsset
    case noShots
    case duplicateShotID(String)
    case invalidShot(String)
    case startsAfterBeginning
    case frameGap(expected: Int, actual: Int)
    case frameOverlap(expected: Int, actual: Int)
    case timeGap(expected: Double, actual: Double)
    case timeOverlap(expected: Double, actual: Double)
    case endsBeforeAsset
    case extendsPastAsset
}

public struct ShotGraph: Hashable, Sendable {
    public let asset: VideoAssetDescriptor
    public let shots: [ShotSegment]

    public init(asset: VideoAssetDescriptor, shots: [ShotSegment]) throws {
        try Self.validate(asset: asset, shots: shots)
        self.asset = asset
        self.shots = shots
    }

    public var coverageRatio: Double {
        guard asset.durationSeconds > 0 else { return 0 }
        let covered = shots.reduce(0) { $0 + $1.timeRange.durationSeconds }
        return min(1, max(0, covered / asset.durationSeconds))
    }

    private static func validate(asset: VideoAssetDescriptor, shots: [ShotSegment]) throws {
        guard asset.durationSeconds.isFinite,
              asset.durationSeconds > 0,
              asset.nominalFrameRate.isFinite,
              asset.nominalFrameRate > 0,
              asset.width > 0,
              asset.height > 0,
              asset.timescale > 0,
              asset.fileSizeBytes >= 0,
              asset.frameCount.map({ $0 > 0 }) ?? true
        else {
            throw ShotGraphValidationError.invalidAsset
        }
        guard !shots.isEmpty else {
            throw ShotGraphValidationError.noShots
        }

        var seen = Set<ShotID>()
        let tolerance = 1 / asset.nominalFrameRate
        for shot in shots {
            guard seen.insert(shot.id).inserted else {
                throw ShotGraphValidationError.duplicateShotID(shot.id.rawValue)
            }
            guard shot.timeRange.startSeconds.isFinite,
                  shot.timeRange.endSeconds.isFinite,
                  shot.timeRange.startSeconds >= 0,
                  shot.timeRange.endSeconds > shot.timeRange.startSeconds,
                  shot.frameRange.startFrame >= 0,
                  shot.frameRange.endFrameExclusive > shot.frameRange.startFrame,
                  shot.boundaryConfidence.isFinite,
                  (0...1).contains(shot.boundaryConfidence),
                  !shot.detectorEvidenceIDs.isEmpty
            else {
                throw ShotGraphValidationError.invalidShot(shot.id.rawValue)
            }
        }

        guard shots[0].frameRange.startFrame == 0,
              abs(shots[0].timeRange.startSeconds) <= tolerance
        else {
            throw ShotGraphValidationError.startsAfterBeginning
        }

        for (previous, current) in zip(shots, shots.dropFirst()) {
            let expectedFrame = previous.frameRange.endFrameExclusive
            if current.frameRange.startFrame > expectedFrame {
                throw ShotGraphValidationError.frameGap(
                    expected: expectedFrame,
                    actual: current.frameRange.startFrame
                )
            }
            if current.frameRange.startFrame < expectedFrame {
                throw ShotGraphValidationError.frameOverlap(
                    expected: expectedFrame,
                    actual: current.frameRange.startFrame
                )
            }

            let expectedTime = previous.timeRange.endSeconds
            if current.timeRange.startSeconds - expectedTime > tolerance {
                throw ShotGraphValidationError.timeGap(
                    expected: expectedTime,
                    actual: current.timeRange.startSeconds
                )
            }
            if expectedTime - current.timeRange.startSeconds > tolerance {
                throw ShotGraphValidationError.timeOverlap(
                    expected: expectedTime,
                    actual: current.timeRange.startSeconds
                )
            }
        }

        guard let last = shots.last else { throw ShotGraphValidationError.noShots }
        if let frameCount = asset.frameCount {
            if last.frameRange.endFrameExclusive < frameCount {
                throw ShotGraphValidationError.endsBeforeAsset
            }
            if last.frameRange.endFrameExclusive > frameCount {
                throw ShotGraphValidationError.extendsPastAsset
            }
        }
        if asset.durationSeconds - last.timeRange.endSeconds > tolerance {
            throw ShotGraphValidationError.endsBeforeAsset
        }
        if last.timeRange.endSeconds - asset.durationSeconds > tolerance {
            throw ShotGraphValidationError.extendsPastAsset
        }
    }
}

public enum AnalysisQuality: String, Codable, Hashable, Sendable {
    case fast
    case balanced
    case accurate
}

public struct ShotKeyframe: Codable, Hashable, Sendable {
    public let shotID: ShotID
    public let frame: SampledFrame
    public let artifactRef: String

    public init(shotID: ShotID, frame: SampledFrame, artifactRef: String) {
        self.shotID = shotID
        self.frame = frame
        self.artifactRef = artifactRef
    }
}

public struct ShotPlaybackDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: ShotID
    public let sourceURL: URL
    public let startSeconds: Double
    public let endSeconds: Double
    public let loops: Bool

    public init(id: ShotID, sourceURL: URL, startSeconds: Double, endSeconds: Double, loops: Bool = true) {
        self.id = id
        self.sourceURL = sourceURL
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.loops = loops
    }
}

public protocol VideoAssetProbing: Sendable {
    func probe(_ source: VideoSource) async throws -> VideoAssetDescriptor
}

public protocol ShotBoundaryDetecting: Sendable {
    func detect(in asset: VideoAssetDescriptor, sourceURL: URL, quality: AnalysisQuality) async throws -> ShotGraph
}

public protocol ShotKeyframeSelecting: Sendable {
    func select(in graph: ShotGraph, sourceURL: URL) async throws -> [ShotKeyframe]
    func select(
        in graph: ShotGraph,
        sourceURL: URL,
        shotIDs: Set<ShotID>,
        framesPerShot: Int
    ) async throws -> [ShotKeyframe]
}

public extension ShotKeyframeSelecting {
    func select(
        in graph: ShotGraph,
        sourceURL: URL,
        shotIDs: Set<ShotID>,
        framesPerShot: Int
    ) async throws -> [ShotKeyframe] {
        let selected = try await select(in: graph, sourceURL: sourceURL)
            .filter { shotIDs.contains($0.shotID) }
        let limit = min(3, max(1, framesPerShot))
        return Dictionary(grouping: selected, by: \.shotID)
            .values
            .flatMap { $0.sorted { $0.frame.timestampSeconds < $1.frame.timestampSeconds }.prefix(limit) }
            .sorted {
                $0.shotID == $1.shotID
                    ? $0.frame.timestampSeconds < $1.frame.timestampSeconds
                    : $0.shotID < $1.shotID
            }
    }
}

extension ShotGraph: Codable {
    private enum CodingKeys: String, CodingKey {
        case asset
        case shots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let asset = try container.decode(VideoAssetDescriptor.self, forKey: .asset)
        let shots = try container.decode([ShotSegment].self, forKey: .shots)
        try self.init(asset: asset, shots: shots)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(asset, forKey: .asset)
        try container.encode(shots, forKey: .shots)
    }
}
