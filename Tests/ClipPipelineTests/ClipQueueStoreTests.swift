import ClipCore
import ClipPipeline
import Foundation
import Testing

@Suite("Clip queue store")
struct ClipQueueStoreTests {
    @Test("enqueue writes one pending JSON file and leaves no temp residue")
    func enqueueWritesPendingClipAndLeavesNoTempResidue() throws {
        let fixture = try QueueFixture()
        let clip = makeClip(id: "clip-atomic")
        let recorder = NotificationRecorder()
        let writer = ClipQueueWriter(
            store: fixture.store,
            notificationPoster: ClipQueueNotificationPoster { recorder.append($0) }
        )

        try writer.enqueue(clip)

        let pendingFiles = try pendingJSONFiles(in: fixture.store.pendingDirectory)
        #expect(pendingFiles.count == 1)
        #expect(try pendingJSONFiles(in: fixture.store.temporaryDirectory).isEmpty)
        #expect(try fixture.store.pendingItems().map(\.clip) == [clip])
        #expect(recorder.names == [ClipQueueWriter.notificationName])
    }

    @Test("corrupt pending JSON is quarantined with a sidecar")
    func corruptPendingJSONIsQuarantinedWithSidecar() throws {
        let fixture = try QueueFixture()
        try fixture.store.prepareDirectories()
        let pendingURL = fixture.store.pendingDirectory.appendingPathComponent("bad.json")
        try Data("{".utf8).write(to: pendingURL)
        let quarantineDate = Date(timeIntervalSince1970: 1_788_000_000)

        let items = try fixture.store.pendingItems(quarantineDate: quarantineDate)

        #expect(items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pendingURL.path))

        let failedURL = fixture.store.failedDirectory.appendingPathComponent("bad.json")
        #expect(FileManager.default.fileExists(atPath: failedURL.path))

        let sidecarURL = fixture.store.failedDirectory.appendingPathComponent("bad.error.json")
        let sidecar = try makeDecoder().decode(
            ClipQueueFailureSidecar.self,
            from: Data(contentsOf: sidecarURL)
        )
        #expect(sidecar.originalFileName == "bad.json")
        #expect(sidecar.failedAt == quarantineDate)
        #expect(!sidecar.reason.isEmpty)
    }

    @Test("pending scan returns items in file-name order")
    func pendingScanReturnsItemsInFilenameOrder() throws {
        let fixture = try QueueFixture()
        try fixture.store.prepareDirectories()
        let earlierClip = makeClip(id: "a-clip")
        let laterClip = makeClip(id: "b-clip")
        try write(clip: laterClip, to: fixture.store.pendingDirectory.appendingPathComponent("b.json"))
        try write(clip: earlierClip, to: fixture.store.pendingDirectory.appendingPathComponent("a.json"))

        let clips = try fixture.store.pendingItems().map(\.clip)

        #expect(clips == [earlierClip, laterClip])
    }

    @Test("concurrent enqueue creates distinct files without overwrite")
    func concurrentEnqueueCreatesDistinctFilesWithoutOverwrite() async throws {
        let fixture = try QueueFixture()
        let writer = ClipQueueWriter(store: fixture.store, notificationPoster: .disabled)
        let clip = makeClip(id: "shared-clip")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try writer.enqueue(clip)
                }
            }

            try await group.waitForAll()
        }

        let pendingFiles = try pendingJSONFiles(in: fixture.store.pendingDirectory)
        let fileNames = Set(pendingFiles.map(\.lastPathComponent))
        #expect(pendingFiles.count == 24)
        #expect(fileNames.count == 24)
        #expect(try fixture.store.pendingItems().count == 24)
    }

    @Test("delete removes a pending file after caller persistence")
    func deleteRemovesPendingFileAfterCallerPersistence() throws {
        let fixture = try QueueFixture()
        let fileURL = try fixture.store.enqueue(makeClip(id: "clip-delete"))
        let item = try #require(fixture.store.pendingItems().first)

        try fixture.store.delete(item)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try fixture.store.pendingItems().isEmpty)
    }
}

private final class QueueFixture {
    let rootURL: URL
    let store: ClipQueueStore

    init() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-clip-queue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL
        self.store = ClipQueueStore(queueDirectory: rootURL.appendingPathComponent("queue", isDirectory: true))
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ name: String) {
        lock.lock()
        storage.append(name)
        lock.unlock()
    }
}

private func makeClip(id: String) -> Clip {
    Clip(
        id: id,
        source: .text("source-\(id)"),
        title: "Title \(id)",
        note: "Note \(id)",
        bodyText: "Body \(id)",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        state: .queued
    )
}

private func write(clip: Clip, to url: URL) throws {
    try makeEncoder().encode(clip).write(to: url)
}

private func pendingJSONFiles(in directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return []
    }

    return try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}
