import Foundation

public struct BoundaryLabel: Codable, Hashable, Sendable {
    public let startFrame: Int
    public let endFrameExclusive: Int
    public let transitionOut: ShotTransition

    public init(startFrame: Int, endFrameExclusive: Int, transitionOut: ShotTransition) {
        self.startFrame = startFrame
        self.endFrameExclusive = endFrameExclusive
        self.transitionOut = transitionOut
    }
}

public struct TranscriptLabel: Codable, Hashable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

public struct OCRTrackLabel: Codable, Hashable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let role: String

    public init(startSeconds: Double, endSeconds: Double, text: String, role: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.role = role
    }
}

public struct CriticalFactLabel: Codable, Hashable, Sendable {
    public let shotIndex: Int
    public let field: String
    public let expected: String

    public init(shotIndex: Int, field: String, expected: String) {
        self.shotIndex = shotIndex
        self.field = field
        self.expected = expected
    }
}

public enum FixtureLabelValidationError: Error, Codable, Hashable, Sendable {
    case invalidFixtureID
    case invalidSHA256
    case invalidMediaMetadata
    case noShots
    case invalidShot(index: Int)
    case timelineDoesNotStartAtZero
    case gap(index: Int, expected: Int, actual: Int)
    case overlap(index: Int, expected: Int, actual: Int)
    case timelineDoesNotReachEnd(expected: Int, actual: Int)
    case invalidTransition(index: Int)
    case invalidTranscript(index: Int)
    case invalidOCRTrack(index: Int)
    case invalidCriticalFact(index: Int)
}

public struct StoryboardFixtureLabel: Codable, Hashable, Sendable {
    public let fixtureID: String
    public let sha256: String
    public let durationSeconds: Double
    public let frameRate: Double
    public let frameCount: Int
    public let shots: [BoundaryLabel]
    public let transcript: [TranscriptLabel]
    public let ocrTracks: [OCRTrackLabel]
    public let criticalFacts: [CriticalFactLabel]

    public init(
        fixtureID: String,
        sha256: String,
        durationSeconds: Double,
        frameRate: Double,
        frameCount: Int,
        shots: [BoundaryLabel],
        transcript: [TranscriptLabel] = [],
        ocrTracks: [OCRTrackLabel] = [],
        criticalFacts: [CriticalFactLabel] = []
    ) {
        self.fixtureID = fixtureID
        self.sha256 = sha256
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.shots = shots
        self.transcript = transcript
        self.ocrTracks = ocrTracks
        self.criticalFacts = criticalFacts
    }

    public func validate() throws {
        guard !fixtureID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FixtureLabelValidationError.invalidFixtureID
        }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard sha256.count == 64,
              sha256.unicodeScalars.allSatisfy(hexadecimal.contains)
        else {
            throw FixtureLabelValidationError.invalidSHA256
        }
        guard durationSeconds.isFinite,
              durationSeconds > 0,
              frameRate.isFinite,
              frameRate > 0,
              frameCount > 0
        else {
            throw FixtureLabelValidationError.invalidMediaMetadata
        }
        guard !shots.isEmpty else {
            throw FixtureLabelValidationError.noShots
        }
        guard shots[0].startFrame == 0 else {
            throw FixtureLabelValidationError.timelineDoesNotStartAtZero
        }

        for (index, shot) in shots.enumerated() {
            guard shot.startFrame >= 0,
                  shot.endFrameExclusive > shot.startFrame,
                  shot.endFrameExclusive <= frameCount
            else {
                throw FixtureLabelValidationError.invalidShot(index: index)
            }
            if index > 0 {
                let expected = shots[index - 1].endFrameExclusive
                if shot.startFrame > expected {
                    throw FixtureLabelValidationError.gap(index: index, expected: expected, actual: shot.startFrame)
                }
                if shot.startFrame < expected {
                    throw FixtureLabelValidationError.overlap(index: index, expected: expected, actual: shot.startFrame)
                }
            }

            let isLast = index == shots.count - 1
            if isLast, shot.transitionOut != .end {
                throw FixtureLabelValidationError.invalidTransition(index: index)
            }
            if !isLast, shot.transitionOut == .start || shot.transitionOut == .end {
                throw FixtureLabelValidationError.invalidTransition(index: index)
            }
        }

        let actualEnd = shots.last?.endFrameExclusive ?? 0
        guard actualEnd == frameCount else {
            throw FixtureLabelValidationError.timelineDoesNotReachEnd(expected: frameCount, actual: actualEnd)
        }

        for (index, segment) in transcript.enumerated() {
            guard Self.isValidRange(start: segment.startSeconds, end: segment.endSeconds, duration: durationSeconds),
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw FixtureLabelValidationError.invalidTranscript(index: index)
            }
        }
        for (index, track) in ocrTracks.enumerated() {
            guard Self.isValidRange(start: track.startSeconds, end: track.endSeconds, duration: durationSeconds),
                  !track.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !track.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw FixtureLabelValidationError.invalidOCRTrack(index: index)
            }
        }
        for (index, fact) in criticalFacts.enumerated() {
            guard shots.indices.contains(fact.shotIndex),
                  !fact.field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !fact.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw FixtureLabelValidationError.invalidCriticalFact(index: index)
            }
        }
    }

    private static func isValidRange(start: Double, end: Double, duration: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start && end <= duration
    }
}
