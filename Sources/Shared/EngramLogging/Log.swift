import os

/// Category-scoped loggers, one per subsystem seam. Runtime branches
/// (fallback, degrade, retry, cancellation) must log through these so field
/// issues are diagnosable from a sysdiagnose.
public enum Log {
    private static let subsystem = "com.gxfn.engram"

    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let rag = Logger(subsystem: subsystem, category: "rag")
    public static let clip = Logger(subsystem: subsystem, category: "clip")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let bench = Logger(subsystem: subsystem, category: "bench")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
}
