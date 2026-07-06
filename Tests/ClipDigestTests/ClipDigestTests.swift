import ClipCore
import ClipDigest
import ClipPipeline
import Foundation
import Persistence
import SwiftData
import Testing

@Test func articleExtractorPrefersArticleAndStripsChrome() throws {
    let html = """
    <html>
      <head><title>Saved &amp; Useful</title><style>.hidden{}</style></head>
      <body>
        <nav>Navigation</nav>
        <article>
          <script>tracking()</script>
          <p>First paragraph.</p>
          <p>Second &amp; final paragraph.</p>
        </article>
      </body>
    </html>
    """

    let article = try ArticleExtractor().extract(html: html)

    #expect(article.title == "Saved & Useful")
    #expect(article.bodyText == "First paragraph.\n\nSecond & final paragraph.")
    #expect(!article.bodyText.contains("Navigation"))
    #expect(!article.bodyText.contains("tracking"))
}

@Test func digestTextClipPersistsIndexedRecordAndDeletesQueueFile() async throws {
    let fixture = try DigestFixture()
    let clip = Clip(
        id: "text-clip",
        source: .text("Plain text body"),
        title: "Plain",
        note: "A note",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let fileURL = try fixture.store.enqueue(clip)
    let service = try fixture.makeService(fetcher: FailingFetcher())

    try await service.digestPending()

    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try fixture.store.pendingItems().isEmpty)
    let snapshot = try await fixture.records.snapshot(id: "text-clip")
    #expect(snapshot.state == .indexed)
    #expect(snapshot.bodyText == "Plain text body")
    #expect(snapshot.indexPreview?.contains("Plain text body") == true)
    #expect(snapshot.failureReason == nil)
}

@Test func digestURLClipFetchesExtractsPersistsAndDeletesQueueFile() async throws {
    let fixture = try DigestFixture()
    let url = try #require(URL(string: "https://example.com/page"))
    let clip = Clip(
        id: "url-clip",
        source: .url(url),
        title: nil,
        note: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_010)
    )
    let fileURL = try fixture.store.enqueue(clip)
    let html = """
    <html>
      <head><title>Fetched Title</title></head>
      <body><main><p>Fetched body.</p><p>Second paragraph.</p></main></body>
    </html>
    """
    let service = try fixture.makeService(fetcher: StaticFetcher(html: html))

    try await service.digestPending()

    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    let snapshot = try await fixture.records.snapshot(id: "url-clip")
    #expect(snapshot.state == .indexed)
    #expect(snapshot.title == "Fetched Title")
    #expect(snapshot.url == url)
    #expect(snapshot.bodyText == "Fetched body.\n\nSecond paragraph.")
    #expect(snapshot.indexPreview?.contains("1. Fetched body.") == true)
}

@Test func digestURLFailureRecordsRetryableFailureAndQuarantinesQueueFile() async throws {
    let fixture = try DigestFixture()
    let url = try #require(URL(string: "https://example.com/slow"))
    let clip = Clip(
        id: "failed-url",
        source: .url(url),
        title: "Slow",
        note: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_020)
    )
    try fixture.store.enqueue(clip)
    let service = try fixture.makeService(fetcher: ThrowingFetcher(code: .timedOut))

    try await service.digestPending()

    #expect(try fixture.store.pendingItems().isEmpty)
    let failedFiles = try jsonFiles(in: fixture.store.failedDirectory)
    #expect(failedFiles.contains { $0.pathExtension == "json" })
    #expect(failedFiles.contains { $0.lastPathComponent.hasSuffix(".error.json") })
    let snapshot = try await fixture.records.snapshot(id: "failed-url")
    #expect(snapshot.state == .failed)
    #expect(snapshot.failureRetryable)
    #expect(snapshot.failureReason?.contains("Network error") == true)
}

@Test func retryFailedClipRequeuesAndCanDigestSuccessfully() async throws {
    let fixture = try DigestFixture()
    let url = try #require(URL(string: "https://example.com/retry"))
    let clip = Clip(
        id: "retry-url",
        source: .url(url),
        title: "Retry",
        note: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_030)
    )
    try fixture.store.enqueue(clip)
    let failingService = try fixture.makeService(fetcher: ThrowingFetcher(code: .timedOut))
    try await failingService.digestPending()

    let retryingService = try fixture.makeService(fetcher: StaticFetcher(html: "<main><p>Recovered.</p></main>"))
    try await retryingService.retryFailedClip(id: "retry-url")
    #expect(try fixture.store.pendingItems().count == 1)

    try await retryingService.digestPending()

    let snapshot = try await fixture.records.snapshot(id: "retry-url")
    #expect(snapshot.state == .indexed)
    #expect(snapshot.bodyText == "Recovered.")
    #expect(snapshot.failureReason == nil)
}

@Test func digestVideoFileRecordsExplicitPendingPipelineFailure() async throws {
    let fixture = try DigestFixture()
    let videoURL = URL(fileURLWithPath: "/tmp/local-video.mov")
    let clip = Clip(
        id: "video-clip",
        source: .videoFile(videoURL),
        title: "Local video",
        note: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_040)
    )
    try fixture.store.enqueue(clip)
    let service = try fixture.makeService(fetcher: FailingFetcher())

    try await service.digestPending()

    #expect(try fixture.store.pendingItems().isEmpty)
    let failedFiles = try jsonFiles(in: fixture.store.failedDirectory)
    #expect(failedFiles.contains { $0.pathExtension == "json" })
    let snapshot = try await fixture.records.snapshot(id: "video-clip")
    #expect(snapshot.url == videoURL)
    #expect(snapshot.state == .failed)
    #expect(!snapshot.failureRetryable)
    #expect(snapshot.failureReason?.contains("W-M3.6") == true)
}

private final class DigestFixture {
    let rootURL: URL
    let store: ClipQueueStore
    let records: ClipRecordStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-clip-digest-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        store = ClipQueueStore(queueDirectory: rootURL.appendingPathComponent("queue", isDirectory: true))
        let container = try PersistenceStack.makeContainer(inMemory: true)
        records = ClipRecordStore(modelContainer: container)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeService(fetcher: any ArticleFetching) throws -> ClipDigestService {
        ClipDigestService(
            queueStore: store,
            recordStore: records,
            fetcher: fetcher,
            now: { Date(timeIntervalSince1970: 1_800_100_000) }
        )
    }
}

private struct StaticFetcher: ArticleFetching {
    let html: String

    func fetchHTML(from url: URL) async throws -> FetchedArticleHTML {
        FetchedArticleHTML(url: url, html: html)
    }
}

private struct ThrowingFetcher: ArticleFetching {
    let code: URLError.Code

    func fetchHTML(from url: URL) async throws -> FetchedArticleHTML {
        throw URLError(code)
    }
}

private struct FailingFetcher: ArticleFetching {
    func fetchHTML(from url: URL) async throws -> FetchedArticleHTML {
        Issue.record("Plain text digestion must not fetch")
        throw URLError(.unsupportedURL)
    }
}

private func jsonFiles(in directory: URL) throws -> [URL] {
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
