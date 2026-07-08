import Foundation

/// One captured memory. Created by the Share Extension with whatever the
/// share sheet handed over; body text may be completed later during digestion
/// (URL clips fetch their article body exactly once, then stay offline).
public struct Clip: Sendable, Hashable, Codable {
    public let id: String
    public let source: ClipSource
    public var title: String?
    public var note: String?
    public var bodyText: String?
    public let createdAt: Date
    public var state: ClipState

    public init(
        id: String,
        source: ClipSource,
        title: String? = nil,
        note: String? = nil,
        bodyText: String? = nil,
        createdAt: Date,
        state: ClipState = .queued
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.note = note
        self.bodyText = bodyText
        self.createdAt = createdAt
        self.state = state
    }
}

public enum ClipSource: Sendable, Hashable, Codable {
    case text(String)
    case url(URL)
    case videoFile(URL)

    public var kind: ClipSourceKind {
        switch self {
        case .text: .text
        case .url: .url
        case .videoFile: .video
        }
    }
}

/// Coarse content type used by the UI to split the two first-class functions:
/// text/url clips (剪藏 knowledge) versus video breakdowns (拆解 studio).
public enum ClipSourceKind: String, Sendable, Codable, CaseIterable {
    case text
    case url
    case video
}

/// Digestion lifecycle. Text clips skip `fetching` because their body arrived
/// with the share; URL clips pass through it for the one-time article fetch.
/// Video clips enter the M3 pipeline through transcription, optional frame
/// analysis, script composition, and finally the shared indexed terminal state.
public enum ClipState: String, Sendable, Codable, CaseIterable {
    case queued
    case fetching
    case indexing
    case indexed
    case failed
    case transcribing
    case analyzing
    case scripting

    public func canTransition(to next: ClipState) -> Bool {
        switch (self, next) {
        case (.queued, .fetching),   // URL clip starts its one-time fetch
             (.queued, .indexing),   // text clip skips fetching
             (.queued, .transcribing),
             (.fetching, .indexing),
             (.fetching, .failed),
             (.indexing, .indexed),
             (.indexing, .failed),
             (.transcribing, .analyzing),
             (.transcribing, .scripting),
             (.transcribing, .failed),
             (.analyzing, .scripting),
             (.analyzing, .failed),
             (.scripting, .indexed),
             (.scripting, .failed),
             (.failed, .queued):     // retry re-queues; indexed is terminal
            return true
        default:
            return false
        }
    }
}

/// Extension-side contract: must stay lightweight enough to run inside the
/// Share Extension's memory ceiling — enqueue persists and returns, nothing else.
public protocol ClipQueuing: Sendable {
    func enqueue(_ clip: Clip) throws
}

/// Main-app-side contract: drains the queue (foreground open or background task),
/// running fetch → chunk → embed → index per clip.
public protocol ClipDigesting: Actor {
    func digestPending() async throws
}

public enum ClipError: Error, Sendable {
    /// Placeholder used by infrastructure stubs; the payload names the roadmap milestone.
    case notImplemented(String)
}
