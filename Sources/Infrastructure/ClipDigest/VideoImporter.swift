import ClipCore
import ClipPipeline
import Foundation

public enum VideoImportError: Error, Equatable, Sendable {
    case nonFileURL(URL)
    case sourceMissing(URL)
}

public struct VideoImporter: Sendable {
    private let videosDirectory: URL
    private let queueStore: ClipQueueStore
    private let fileExists: @Sendable (URL) -> Bool
    private let createDirectory: @Sendable (URL) throws -> Void
    private let copyItem: @Sendable (URL, URL) throws -> Void
    private let removeItem: @Sendable (URL) throws -> Void
    private let idGenerator: @Sendable () -> String
    private let now: @Sendable () -> Date

    public init(
        videosDirectory: URL,
        queueStore: ClipQueueStore,
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            videosDirectory: videosDirectory,
            queueStore: queueStore,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            idGenerator: idGenerator,
            now: now
        )
    }

    public init(
        videosDirectory: URL,
        queueStore: ClipQueueStore,
        fileExists: @escaping @Sendable (URL) -> Bool,
        createDirectory: @escaping @Sendable (URL) throws -> Void,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void,
        removeItem: @escaping @Sendable (URL) throws -> Void,
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.videosDirectory = videosDirectory
        self.queueStore = queueStore
        self.fileExists = fileExists
        self.createDirectory = createDirectory
        self.copyItem = copyItem
        self.removeItem = removeItem
        self.idGenerator = idGenerator
        self.now = now
    }

    @discardableResult
    public func importVideo(from pickedURL: URL) throws -> Clip {
        guard pickedURL.isFileURL else {
            throw VideoImportError.nonFileURL(pickedURL)
        }
        guard fileExists(pickedURL) else {
            throw VideoImportError.sourceMissing(pickedURL)
        }

        try createDirectory(videosDirectory)

        let id = idGenerator()
        let destinationURL = videosDirectory.appendingPathComponent(
            "\(id).\(videoFileExtension(from: pickedURL))",
            isDirectory: false
        )

        try? removeItem(destinationURL)
        do {
            try copyItem(pickedURL, destinationURL)
        } catch {
            try? removeItem(destinationURL)
            throw error
        }

        let clip = Clip(
            id: id,
            source: .videoFile(destinationURL),
            title: pickedURL.deletingPathExtension().lastPathComponent,
            note: nil,
            createdAt: now(),
            state: .queued
        )

        do {
            try queueStore.enqueue(clip)
            return clip
        } catch {
            try? removeItem(destinationURL)
            throw error
        }
    }
}

private func videoFileExtension(from url: URL) -> String {
    let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pathExtension.isEmpty else {
        return "mov"
    }
    return pathExtension
}
