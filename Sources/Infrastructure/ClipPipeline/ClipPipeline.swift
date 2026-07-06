import AppGroupSupport
import ClipCore
import Foundation

#if canImport(Darwin)
import Darwin

@_silgen_name("notify_post")
private func engram_notify_post(_ name: UnsafePointer<CChar>) -> UInt32
#endif

public struct ClipQueueItem: Equatable, Sendable {
    public let clip: Clip
    public let fileURL: URL

    public init(clip: Clip, fileURL: URL) {
        self.clip = clip
        self.fileURL = fileURL
    }
}

public struct ClipQueueFailureSidecar: Codable, Equatable, Sendable {
    public let originalFileName: String
    public let failedAt: Date
    public let reason: String

    public init(originalFileName: String, failedAt: Date, reason: String) {
        self.originalFileName = originalFileName
        self.failedAt = failedAt
        self.reason = reason
    }
}

public enum ClipQueueError: Error, Equatable, Sendable {
    case appGroupUnavailable(String)
    case pendingFileMissing(URL)
}

public struct ClipQueueNotificationPoster: Sendable {
    private let post: @Sendable (String) -> Void

    public init(post: @escaping @Sendable (String) -> Void) {
        self.post = post
    }

    public func post(_ name: String) {
        post(name)
    }

    public static let disabled = ClipQueueNotificationPoster { _ in }

    public static let darwin = ClipQueueNotificationPoster { name in
        #if canImport(Darwin)
        _ = name.withCString { engram_notify_post($0) }
        #else
        _ = name
        #endif
    }
}

public struct ClipQueueStore: Sendable {
    public let queueDirectory: URL
    public let pendingDirectory: URL
    public let failedDirectory: URL
    public let temporaryDirectory: URL

    public init(queueDirectory: URL) {
        self.queueDirectory = queueDirectory
        self.pendingDirectory = queueDirectory.appendingPathComponent("pending", isDirectory: true)
        self.failedDirectory = queueDirectory.appendingPathComponent("failed", isDirectory: true)
        self.temporaryDirectory = queueDirectory.appendingPathComponent("tmp", isDirectory: true)
    }

    public init(locations: AppGroupLocations) {
        self.init(queueDirectory: locations.queueDirectory)
    }

    @discardableResult
    public func enqueue(_ clip: Clip) throws -> URL {
        try prepareDirectories()

        let fileName = "\(UUID().uuidString).json"
        let finalURL = pendingDirectory.appendingPathComponent(fileName, isDirectory: false)
        let temporaryURL = temporaryDirectory.appendingPathComponent("\(fileName).tmp", isDirectory: false)
        let data = try Self.makeEncoder().encode(clip)

        try? FileManager.default.removeItem(at: temporaryURL)
        try data.write(to: temporaryURL)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        return finalURL
    }

    public func pendingItems(quarantineDate: Date = Date()) throws -> [ClipQueueItem] {
        try prepareDirectories()

        let files = try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var items: [ClipQueueItem] = []
        for fileURL in files {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard resourceValues.isRegularFile == true else {
                    continue
                }

                let data = try Data(contentsOf: fileURL)
                let clip = try Self.makeDecoder().decode(Clip.self, from: data)
                items.append(ClipQueueItem(clip: clip, fileURL: fileURL))
            } catch {
                _ = try quarantineUnreadableFile(fileURL, reason: String(describing: error), failedAt: quarantineDate)
            }
        }

        return items
    }

    public func delete(_ item: ClipQueueItem) throws {
        if FileManager.default.fileExists(atPath: item.fileURL.path) {
            try FileManager.default.removeItem(at: item.fileURL)
        } else {
            throw ClipQueueError.pendingFileMissing(item.fileURL)
        }
    }

    @discardableResult
    public func moveToFailed(
        _ item: ClipQueueItem,
        reason: String,
        failedAt: Date = Date()
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            throw ClipQueueError.pendingFileMissing(item.fileURL)
        }

        return try movePendingFileToFailed(item.fileURL, reason: reason, failedAt: failedAt)
    }

    public func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    private func quarantineUnreadableFile(_ fileURL: URL, reason: String, failedAt: Date) throws -> URL {
        try movePendingFileToFailed(fileURL, reason: reason, failedAt: failedAt)
    }

    private func movePendingFileToFailed(_ fileURL: URL, reason: String, failedAt: Date) throws -> URL {
        try prepareDirectories()

        let failedURL = uniqueFailedURL(for: fileURL.lastPathComponent)
        try FileManager.default.moveItem(at: fileURL, to: failedURL)

        let sidecar = ClipQueueFailureSidecar(
            originalFileName: fileURL.lastPathComponent,
            failedAt: failedAt,
            reason: reason
        )
        let sidecarURL = failedURL.deletingPathExtension().appendingPathExtension("error.json")
        try Self.makeEncoder().encode(sidecar).write(to: sidecarURL)

        return failedURL
    }

    private func uniqueFailedURL(for fileName: String) -> URL {
        let proposedURL = failedDirectory.appendingPathComponent(fileName, isDirectory: false)
        if !FileManager.default.fileExists(atPath: proposedURL.path) {
            return proposedURL
        }

        let baseName = proposedURL.deletingPathExtension().lastPathComponent
        let pathExtension = proposedURL.pathExtension
        let uniqueName = "\(baseName)-\(UUID().uuidString).\(pathExtension)"
        return failedDirectory.appendingPathComponent(uniqueName, isDirectory: false)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Extension-side queue writer (M2). Runs inside the Share Extension's memory
/// ceiling: persist the clip into the App Group queue, post the Darwin
/// notification, return — no fetching, no inference, ever (dependency rule 5).
public struct ClipQueueWriter: ClipQueuing {
    public static let notificationName = "com.gxfn.engram.clip-enqueued"

    private let store: ClipQueueStore?
    private let notificationPoster: ClipQueueNotificationPoster

    public init(notificationPoster: ClipQueueNotificationPoster = .darwin) {
        self.store = nil
        self.notificationPoster = notificationPoster
    }

    public init(
        store: ClipQueueStore,
        notificationPoster: ClipQueueNotificationPoster = .darwin
    ) {
        self.store = store
        self.notificationPoster = notificationPoster
    }

    public func enqueue(_ clip: Clip) throws {
        try resolvedStore().enqueue(clip)
        notificationPoster.post(Self.notificationName)
    }

    private func resolvedStore() throws -> ClipQueueStore {
        if let store {
            return store
        }

        let locations = try EngramAppGroup.locations()
        return ClipQueueStore(locations: locations)
    }
}

/// Main-app-side digester placeholder (M2). Queue file deletion is exposed on
/// `ClipQueueStore` so future digestion can remove a file only after the caller
/// has durably persisted the clip record.
public actor ClipDigestService: ClipDigesting {
    public init() {}

    public func digestPending() async throws {
        throw ClipError.notImplemented("M2")
    }
}
