import ClipCore
import ClipDigest
import ClipPipeline
import Foundation
import Persistence
import ScriptCore
import SwiftData
import Testing
import VideoUnderstanding

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

@Test func digestVideoFileUsesAnalyzerScriptAndSharedIndexingPath() async throws {
    let fixture = try DigestFixture()
    let videoURL = URL(fileURLWithPath: "/tmp/local-video.mov")
    let clip = Clip(
        id: "video-clip",
        source: .videoFile(videoURL),
        title: nil,
        note: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_040)
    )
    let fileURL = try fixture.store.enqueue(clip)
    let script = fixtureScript(sourceID: "video-clip", title: "Scripted Video")
    let analyzer = RecordingVideoAnalyzer(result: script)
    let service = try fixture.makeService(fetcher: FailingFetcher(), videoAnalyzer: analyzer)

    try await service.digestPending()

    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try fixture.store.pendingItems().isEmpty)

    let snapshot = try await fixture.records.snapshot(id: "video-clip")
    #expect(snapshot.url == videoURL)
    #expect(snapshot.state == .indexed)
    #expect(snapshot.title == "Scripted Video")
    #expect(snapshot.bodyText == ScriptRendering.indexableText(script))
    #expect(try ClipRecordScriptJSON.decode(try #require(snapshot.scriptJSON)) == script)
    #expect(snapshot.videoFileName == "local-video.mov")
    #expect(snapshot.indexPreview?.contains("1. Scripted Video") == true)
    #expect(snapshot.failureReason == nil)

    let sources = await analyzer.sources
    #expect(sources.map(\.id) == ["video-clip"])
    #expect(sources.map(\.localFileURL) == [videoURL])
    #expect(sources.map(\.importedAt) == [clip.createdAt])
    #expect(await analyzer.stageCalls == [.transcribing, .scripting])
}

@Test func digestVideoFileNoAudioFailureMarksFailedAndMovesQueueFile() async throws {
    let fixture = try DigestFixture()
    let videoURL = URL(fileURLWithPath: "/tmp/no-audio.mov")
    let clip = Clip(
        id: "video-no-audio",
        source: .videoFile(videoURL),
        title: "No audio",
        note: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_041)
    )
    try fixture.store.enqueue(clip)
    let analyzer = RecordingVideoAnalyzer(
        error: VideoUnderstandingError.noAudioTrack,
        stages: [.transcribing]
    )
    let service = try fixture.makeService(fetcher: FailingFetcher(), videoAnalyzer: analyzer)

    try await service.digestPending()

    #expect(try fixture.store.pendingItems().isEmpty)
    let failedFiles = try jsonFiles(in: fixture.store.failedDirectory)
    #expect(failedFiles.contains { $0.pathExtension == "json" })
    #expect(failedFiles.contains { $0.lastPathComponent.hasSuffix(".error.json") })

    let snapshot = try await fixture.records.snapshot(id: "video-no-audio")
    #expect(snapshot.state == .failed)
    #expect(!snapshot.failureRetryable)
    #expect(snapshot.failureReason?.contains("no audio") == true)
    #expect(await analyzer.stageCalls == [.transcribing])
}

@Test func digestVideoFileVisionFailureFallsBackToTranscriptOnlyAndStillIndexes() async throws {
    let fixture = try DigestFixture()
    let videoURL = URL(fileURLWithPath: "/tmp/vlm-fallback.mov")
    let clip = Clip(
        id: "video-vlm-fallback",
        source: .videoFile(videoURL),
        title: nil,
        note: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_042)
    )
    try fixture.store.enqueue(clip)

    let transcript = [
        TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "先介绍这个产品。"),
        TranscriptSegment(startSeconds: 2, endSeconds: 4, text: "再展示核心步骤。"),
    ]
    let frames = [SampledFrame(timestampSeconds: 1, jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]))]
    let textScript = fixtureScript(
        sourceID: "video-vlm-fallback",
        title: "转写脚本",
        visualDescription: ""
    )
    let transcriber = RecordingTranscriber(transcript: transcript)
    let sampler = RecordingFrameSampler(frames: frames)
    let visionComposer = FailingVisionComposer(error: VideoUnderstandingError.visionUnavailable("VLM unavailable"))
    let textComposer = RecordingTextComposer(script: textScript)
    let analyzer = VideoAnalyzer(
        transcriber: transcriber,
        sampler: sampler,
        visionComposer: visionComposer,
        textComposer: textComposer,
        maxFrames: 4
    )
    let service = try fixture.makeService(fetcher: FailingFetcher(), videoAnalyzer: analyzer)

    try await service.digestPending()

    let snapshot = try await fixture.records.snapshot(id: "video-vlm-fallback")
    #expect(snapshot.state == .indexed)
    #expect(snapshot.title == "转写脚本")
    #expect(snapshot.bodyText == ScriptRendering.indexableText(textScript))
    #expect(snapshot.failureReason == nil)
    #expect(await transcriber.sources.map(\.id) == ["video-vlm-fallback"])
    #expect(await sampler.maxFrameRequests == [4])
    let visionCalls = await visionComposer.calls
    let textCalls = await textComposer.calls
    #expect(visionCalls.count == 1)
    #expect(visionCalls[0].keyframes == frames)
    #expect(textCalls.count == 1)
    #expect(textCalls[0].transcript == transcript)
}

@Test func digestVideoFileWithoutAnalyzerRecordsConfigurationFailure() async throws {
    let fixture = try DigestFixture()
    let videoURL = URL(fileURLWithPath: "/tmp/local-video.mov")
    let clip = Clip(
        id: "video-without-analyzer",
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
    let snapshot = try await fixture.records.snapshot(id: "video-without-analyzer")
    #expect(snapshot.url == videoURL)
    #expect(snapshot.state == .failed)
    #expect(!snapshot.failureRetryable)
    #expect(snapshot.failureReason?.contains("not configured") == true)
}

@Test func retryFailedVideoClipRequeuesRecoverableVideoSourceFromVideosDirectory() async throws {
    let fixture = try DigestFixture()
    let originalURL = URL(fileURLWithPath: "/private/tmp/import-session/retry-video.mov")
    let videosDirectory = fixture.rootURL.appendingPathComponent("videos", isDirectory: true)
    let clip = Clip(
        id: "video-retry-source",
        source: .videoFile(originalURL),
        title: "Retry video",
        note: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_043)
    )
    try fixture.store.enqueue(clip)
    let analyzer = RecordingVideoAnalyzer(
        error: VideoUnderstandingError.transcriptionUnavailable("Speech service unavailable"),
        stages: [.transcribing]
    )
    let service = try fixture.makeService(
        fetcher: FailingFetcher(),
        videoAnalyzer: analyzer,
        videoDirectoryURL: videosDirectory
    )

    try await service.digestPending()

    var snapshot = try await fixture.records.snapshot(id: "video-retry-source")
    #expect(snapshot.url == originalURL)
    #expect(snapshot.videoFileName == "retry-video.mov")
    #expect(snapshot.state == .failed)
    #expect(snapshot.failureRetryable)
    #expect(snapshot.failureReason?.contains("transcription unavailable") == true)

    try await service.retryFailedClip(id: "video-retry-source")

    let retryItem = try #require(try fixture.store.pendingItems().first)
    #expect(retryItem.clip.source == .videoFile(videosDirectory.appendingPathComponent("retry-video.mov")))
    snapshot = try await fixture.records.snapshot(id: "video-retry-source")
    #expect(snapshot.state == .queued)
    #expect(snapshot.failureReason == nil)
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

    func makeService(
        fetcher: any ArticleFetching,
        indexer: any ClipDigestIndexing = DigestPreviewIndexer(),
        videoAnalyzer: (any VideoAnalyzing)? = nil,
        videoDirectoryURL: URL? = nil
    ) throws -> ClipDigestService {
        ClipDigestService(
            queueStore: store,
            recordStore: records,
            fetcher: fetcher,
            indexer: indexer,
            videoAnalyzer: videoAnalyzer,
            videoDirectoryURL: videoDirectoryURL,
            now: { Date(timeIntervalSince1970: 1_800_100_000) }
        )
    }
}

private actor RecordingVideoAnalyzer: VideoAnalyzing {
    private let result: Script?
    private let error: Error?
    private let stages: [ClipState]
    private(set) var sources: [VideoSource] = []
    private(set) var stageCalls: [ClipState] = []

    init(
        result: Script? = nil,
        error: Error? = nil,
        stages: [ClipState] = [.transcribing, .scripting]
    ) {
        self.result = result
        self.error = error
        self.stages = stages
    }

    func analyze(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> Script {
        sources.append(source)
        for stage in stages {
            await onStage(stage)
            stageCalls.append(stage)
        }
        if let error {
            throw error
        }
        return try #require(result)
    }
}

private actor RecordingTranscriber: Transcriber {
    private let transcript: [TranscriptSegment]
    private let error: Error?
    private(set) var sources: [VideoSource] = []

    init(transcript: [TranscriptSegment] = [], error: Error? = nil) {
        self.transcript = transcript
        self.error = error
    }

    func transcribe(_ source: VideoSource) async throws -> [TranscriptSegment] {
        sources.append(source)
        if let error {
            throw error
        }
        return transcript
    }
}

private actor RecordingFrameSampler: FrameSampler {
    private let frames: [SampledFrame]
    private let error: Error?
    private(set) var maxFrameRequests: [Int] = []

    init(frames: [SampledFrame] = [], error: Error? = nil) {
        self.frames = frames
        self.error = error
    }

    func sampleKeyFrames(_ source: VideoSource, maxFrames: Int) async throws -> [SampledFrame] {
        _ = source
        maxFrameRequests.append(maxFrames)
        if let error {
            throw error
        }
        return frames
    }
}

private actor FailingVisionComposer: VisionScriptComposing {
    struct Call: Sendable {
        let sourceID: String
        let transcript: [TranscriptSegment]
        let keyframes: [SampledFrame]
    }

    private let error: Error
    private(set) var calls: [Call] = []

    init(error: Error) {
        self.error = error
    }

    func compose(
        sourceID: String,
        transcript: [TranscriptSegment],
        keyframes: [SampledFrame]
    ) async throws -> Script {
        calls.append(Call(sourceID: sourceID, transcript: transcript, keyframes: keyframes))
        throw error
    }
}

private actor RecordingTextComposer: TextScriptComposing {
    struct Call: Sendable {
        let sourceID: String
        let transcript: [TranscriptSegment]
    }

    private let script: Script
    private(set) var calls: [Call] = []

    init(script: Script) {
        self.script = script
    }

    func compose(sourceID: String, transcript: [TranscriptSegment]) async throws -> Script {
        calls.append(Call(sourceID: sourceID, transcript: transcript))
        return script
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

private func fixtureScript(
    sourceID: String,
    title: String = "Video Script",
    visualDescription: String = "Presenter holds the product toward camera."
) -> Script {
    Script(
        id: "script-\(sourceID)",
        videoSourceID: sourceID,
        title: title,
        summary: "A generated storyboard.",
        shots: [
            StoryboardShot(
                index: 0,
                startSeconds: 0,
                endSeconds: 4,
                narration: "Narration from transcript.",
                visualDescription: visualDescription,
                pacingNote: "Steady cut"
            )
        ],
        createdAt: Date(timeIntervalSince1970: 1_800_000_500)
    )
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
