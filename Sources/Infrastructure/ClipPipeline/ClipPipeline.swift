import ClipCore
import RAGCore

/// Extension-side queue writer (M2). Runs inside the Share Extension's memory
/// ceiling: persist the clip into the App Group queue, post the Darwin
/// notification, return — no fetching, no inference, ever (dependency rule 5).
public struct ClipQueueWriter: ClipQueuing {
    public init() {}

    public func enqueue(_ clip: Clip) throws {
        throw ClipError.notImplemented("M2")
    }
}

/// Main-app-side digester (M2). Drains the queue on foreground open (the
/// guaranteed path) and via BGTaskScheduler (the accelerator): URL clips get
/// their one-time article fetch, then chunk → embed → index → Spotlight.
public actor ClipDigestService: ClipDigesting {
    public init() {}

    public func digestPending() async throws {
        throw ClipError.notImplemented("M2")
    }
}
