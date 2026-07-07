import AppGroupSupport
import AppShell
import AskFeature
import BenchFeature
import ClipCore
import ClipDigest
import ClipPipeline
import EngineKit
import Foundation
import MemoryFeature
import ModelStore
import Persistence
import RAGCore
import ScriptCore
import SwiftData
import Testing
import VideoUnderstanding

@MainActor
@Test func settingsSelectionAndConfigUpdateSharedDependenciesAndPersist() {
    let defaults = makeDefaults()
    let engineA = FakeEngine(id: "engine-a", displayName: "Engine A")
    let engineB = FakeEngine(id: "engine-b", displayName: "Engine B")
    let dependencies = AppDependencies(
        engines: [engineA, engineB],
        activeEngine: engineA,
        activeModel: ModelCatalog.qwen3_1_7B_4bit,
        generationConfig: GenerationConfig(temperature: 0.3, topP: 0.8, maxTokens: 256),
        defaults: defaults
    )
    let settings = dependencies.makeSettingsViewModel()

    settings.selectEngine(id: "engine-b")
    settings.selectModel(ModelCatalog.qwen3_4B_4bit)
    settings.setTemperature(1.4)
    settings.setTopP(0.6)
    settings.setMaxTokens(512)

    #expect(dependencies.activeEngine.descriptor.id == "engine-b")
    #expect(dependencies.activeModel == ModelCatalog.qwen3_4B_4bit)
    #expect(dependencies.generationConfig == GenerationConfig(temperature: 1.4, topP: 0.6, maxTokens: 512))

    let restored = AppDependencies(
        engines: [engineA, engineB],
        deviceCapability: DeviceCapability(physicalMemoryBytes: 8 * DeviceCapability.gibibyte),
        defaults: defaults
    )
    #expect(restored.activeEngine.descriptor.id == "engine-b")
    #expect(restored.activeModel == ModelCatalog.qwen3_4B_4bit)
    #expect(restored.generationConfig == GenerationConfig(temperature: 1.4, topP: 0.6, maxTokens: 512))
}

@MainActor
@Test func appShellSettingsBridgeReadsModelStoreDownloadState() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramAppShellTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let modelsDirectory = root.appendingPathComponent("Models", isDirectory: true)
    let store = ModelStore(modelsDirectory: modelsDirectory)
    let modelDirectory = try await store.localURL(for: ModelCatalog.qwen3_1_7B_4bit)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 7).write(to: modelDirectory.appendingPathComponent("weights.safetensors"))

    let dependencies = AppDependencies(
        engines: [FakeEngine(id: "fake", displayName: "Fake")],
        modelStore: store,
        activeModel: ModelCatalog.qwen3_1_7B_4bit,
        deviceCapability: DeviceCapability(physicalMemoryBytes: 4 * DeviceCapability.gibibyte),
        defaults: nil
    )
    let settings = dependencies.makeSettingsViewModel()

    await settings.refresh()

    let downloaded = settings.models.first { $0.id == ModelCatalog.qwen3_1_7B_4bit.id }
    #expect(downloaded?.isDownloaded == true)
    #expect(downloaded?.storageBytes == 7)
    #expect(settings.recommendedModel?.id == ModelCatalog.qwen3_1_7B_4bit.id)
}

@MainActor
@Test func appShellSettingsBridgeInstallsLocalModelIntoModelStore() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramAppShellInstallTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let modelsDirectory = root.appendingPathComponent("Models", isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("VerifiedModel", isDirectory: true)
    try makeLocalModelFixture(at: sourceDirectory)

    let store = ModelStore(modelsDirectory: modelsDirectory)
    let model = ModelCatalog.qwen3_1_7B_4bit
    let dependencies = AppDependencies(
        engines: [FakeEngine(id: "fake", displayName: "Fake")],
        modelStore: store,
        activeModel: ModelCatalog.qwen3_4B_4bit,
        deviceCapability: DeviceCapability(physicalMemoryBytes: 4 * DeviceCapability.gibibyte),
        defaults: nil
    )
    let settings = dependencies.makeSettingsViewModel()
    await settings.refresh()

    let row = try #require(settings.models.first { $0.id == model.id })

    await settings.installLocalModel(row, from: sourceDirectory)

    #expect(settings.errorMessage == nil)
    #expect(settings.models.first { $0.id == model.id }?.isDownloaded == true)
    #expect(try await store.isDownloaded(model))
    #expect(dependencies.activeModel == model)
}

@MainActor
@Test func appShellSettingsBridgeDownloadsPublicModelIntoModelStore() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramAppShellDownloadTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let modelsDirectory = root.appendingPathComponent("Models", isDirectory: true)
    let downloader = AppShellFixtureSnapshotDownloader()
    let store = ModelStore(modelsDirectory: modelsDirectory, snapshotDownloader: downloader)
    let model = ModelCatalog.qwen3_1_7B_4bit
    let dependencies = AppDependencies(
        engines: [FakeEngine(id: "fake", displayName: "Fake")],
        modelStore: store,
        activeModel: ModelCatalog.qwen3_4B_4bit,
        deviceCapability: DeviceCapability(physicalMemoryBytes: 4 * DeviceCapability.gibibyte),
        defaults: nil
    )
    let settings = dependencies.makeSettingsViewModel()
    await settings.refresh()

    let row = try #require(settings.models.first { $0.id == model.id })

    await settings.download(row)

    #expect(settings.errorMessage == nil)
    #expect(settings.downloadProgress?.fractionCompleted == 1)
    #expect(settings.models.first { $0.id == model.id }?.isDownloaded == true)
    #expect(try await store.isDownloaded(model))
    #expect(dependencies.activeModel == model)
    #expect(await downloader.callCount == 1)
}

@MainActor
@Test func appShellMemoryBridgeDigestsQueueIntoViewModelItems() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramAppShellMemoryTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let queueStore = ClipQueueStore(queueDirectory: root.appendingPathComponent("queue", isDirectory: true))
    let container = try PersistenceStack.makeContainer(inMemory: true)
    let recordStore = ClipRecordStore(modelContainer: container)
    let digestService = ClipDigestService(queueStore: queueStore, recordStore: recordStore)
    try queueStore.enqueue(Clip(
        id: "memory-bridge",
        source: .text("Body from queue"),
        title: "Queued Memory",
        note: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_100)
    ))

    let dependencies = AppDependencies(
        engines: [FakeEngine(id: "fake", displayName: "Fake")],
        defaults: nil,
        clipDigestService: digestService
    )
    let memory = dependencies.makeMemoryViewModel()

    await memory.digestAndRefresh()

    #expect(memory.items.count == 1)
    #expect(memory.items.first?.id == "memory-bridge")
    #expect(memory.items.first?.state == .indexed)
    #expect(memory.items.first?.bodyText == "Body from queue")
}

@MainActor
@Test func appShellMemoryBridgeImportsVideoAndShowsQueuedClip() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramAppShellVideoImportTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let queueStore = ClipQueueStore(queueDirectory: root.appendingPathComponent("queue", isDirectory: true))
    let container = try PersistenceStack.makeContainer(inMemory: true)
    let recordStore = ClipRecordStore(modelContainer: container)
    let videosDirectory = root.appendingPathComponent("videos", isDirectory: true)
    let digestService = ClipDigestService(
        queueStore: queueStore,
        recordStore: recordStore,
        videoDirectoryURL: videosDirectory
    )
    let pickedURL = root.appendingPathComponent("picked-video.mov", isDirectory: false)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([0x10, 0x11, 0x12]).write(to: pickedURL)

    let dependencies = AppDependencies(
        engines: [FakeEngine(id: "fake", displayName: "Fake")],
        defaults: nil,
        clipDigestService: digestService
    )
    let memory = dependencies.makeMemoryViewModel()

    await memory.importVideo(.file(pickedURL))

    let item = try #require(memory.items.first)
    let copiedURL = try #require(item.sourceURL)
    #expect(memory.items.count == 1)
    #expect(item.state == .queued)
    #expect(copiedURL.deletingLastPathComponent() == videosDirectory)
    #expect(copiedURL.pathExtension == "mov")
    #expect(try Data(contentsOf: copiedURL) == Data([0x10, 0x11, 0x12]))
    #expect(try queueStore.pendingItems().count == 1)
    #expect(memory.errorMessage == nil)
}

@MainActor
@Test func appShellLiveAssemblyDigestsImportedVideoIntoRetrievalCitations() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramAppShellVideoAssemblyTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let locations = try makeAppShellLocations(root: root)
    let modelStore = ModelStore(modelsDirectory: locations.modelsDirectory)
    let qwenVLDirectory = try await modelStore.localURL(for: ModelCatalog.qwen3VL_4B_4bit)
    let engine = FakeEngine(id: "fake", displayName: "Fake")
    let analyzer = AppShellRecordingVideoAnalyzer()
    let container = try PersistenceStack.makeContainer(inMemory: true)
    let dependencies = AppDependencies(
        engines: [engine],
        activeEngine: engine,
        modelStore: modelStore,
        activeModel: ModelCatalog.qwen3_1_7B_4bit,
        generationConfig: GenerationConfig(temperature: 0.2, topP: 0.9, maxTokens: 256),
        defaults: nil,
        modelContainer: container,
        videoAnalyzer: analyzer,
        appGroupLocations: locations,
        retrievalEmbeddingEngine: AppShellTestEmbeddingEngine()
    )
    let memory = dependencies.makeMemoryViewModel()
    let pickedURL = root.appendingPathComponent("picked-video.mov", isDirectory: false)
    try Data([0x20, 0x21, 0x22, 0x23]).write(to: pickedURL)

    #expect(modelStore.modelDirectoryRoot == locations.modelsDirectory)
    #expect(qwenVLDirectory.path.hasPrefix(locations.modelsDirectory.path))
    #expect(dependencies.clipDigestService != nil)
    #expect(dependencies.retriever != nil)

    await memory.importVideo(.file(pickedURL))

    let queued = try #require(memory.items.first)
    let copiedVideoURL = try #require(queued.sourceURL)
    #expect(queued.state == .queued)
    #expect(copiedVideoURL.deletingLastPathComponent() == locations.videosDirectory)

    await memory.digestAndRefresh()

    #expect(memory.errorMessage == nil)
    let indexed = try #require(memory.items.first { $0.id == queued.id })
    #expect(indexed.state == .indexed)
    #expect(indexed.title == "picked-video")
    #expect(indexed.bodyText?.contains("Raincoat Closeup") == true)
    #expect(indexed.bodyText?.contains("红色雨衣") == true)
    #expect(indexed.indexPreview?.contains("红色雨衣") == true)

    let retriever = try #require(dependencies.retriever)
    let results = try await retriever.retrieve(question: "红色雨衣 特写", topK: 4)
    #expect(results.contains { result in
        result.citation.clipID == queued.id
            && result.chunk.text.contains("红色雨衣")
            && result.citation.snippet.contains("红色雨衣")
    })

    #expect(await analyzer.sources.map(\.id) == [queued.id])
    #expect(await analyzer.sources.map(\.localFileURL) == [copiedVideoURL])
    #expect(await analyzer.stageCalls == [.transcribing, .scripting])
}

@MainActor
@Test func appLaunchContextRegistersClipDigestTriggersDuringInitialization() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EngramAppShellLaunchTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let queueStore = ClipQueueStore(queueDirectory: root.appendingPathComponent("queue", isDirectory: true))
    let container = try PersistenceStack.makeContainer(inMemory: true)
    let recordStore = ClipRecordStore(modelContainer: container)
    let digestService = ClipDigestService(queueStore: queueStore, recordStore: recordStore)
    let scheduler = FakeBackgroundScheduler()
    let dependencies = AppDependencies(
        engines: [FakeEngine(id: "fake", displayName: "Fake")],
        defaults: nil,
        clipDigestService: digestService,
        clipDigestBackgroundScheduler: scheduler
    )

    _ = AppLaunchContext(dependencies: dependencies, modelContainer: nil)

    #expect(scheduler.registerCallCount == 1)
    #expect(scheduler.hasRegisteredHandler)
}

@MainActor
@Test func appShellBuildsAskViewModelWithInjectedRetrieverAndCitationRoute() async {
    let citation = CitationRef(
        chunkID: "chunk-route",
        clipID: "clip-route",
        snippet: "Route snippet"
    )
    let dependencies = AppDependencies(
        engines: [FakeEngine(id: "fake", displayName: "Fake")],
        activeModel: ModelCatalog.qwen3_1_7B_4bit,
        defaults: nil,
        retriever: FakeRetriever(results: [
            RetrievedChunk(
                chunk: Chunk(
                    id: "chunk-route",
                    clipID: "clip-route",
                    text: "Route evidence",
                    indexInClip: 0,
                    preview: "Route snippet"
                ),
                score: 0.04,
                citation: citation
            ),
        ])
    )
    let ask = dependencies.makeAskViewModel()

    guard let task = ask.send("Route?") else {
        Issue.record("Expected Ask send to start")
        return
    }

    await task.value

    #expect(ask.messages[1].citations == [citation])

    let target = AppDependencies.memoryNavigationTarget(for: citation)
    #expect(target.clipID == "clip-route")
    #expect(target.chunkID == "chunk-route")
}

@MainActor
@Test func appShellBuildsBenchViewModelWithRetrievalEvalRunner() async throws {
    let dependencies = AppDependencies(
        engines: [FakeEngine(id: "fake", displayName: "Fake")],
        activeModel: ModelCatalog.qwen3_1_7B_4bit,
        defaults: nil
    )
    let bench = dependencies.makeBenchViewModel()

    let task = try #require(bench.runRetrievalEval())
    await task.value

    let hybrid = try #require(bench.latestRetrievalEval?.result(for: .hybrid))
    #expect(hybrid.recallAt8 >= 0.8)
    #expect(bench.latestRetrievalEval?.questionCount == 24)
}

private func makeDefaults() -> UserDefaults {
    let suiteName = "EngramAppShellTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func makeLocalModelFixture(at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 2).write(to: directory.appendingPathComponent("config.json"))
    try Data(repeating: 0x42, count: 3).write(to: directory.appendingPathComponent("tokenizer.json"))
    try Data(repeating: 0x43, count: 5).write(to: directory.appendingPathComponent("model.safetensors"))
}

private func makeAppShellLocations(root: URL) throws -> AppGroupLocations {
    let locations = AppGroupLocations(
        groupIdentifier: "group.com.gxfn.engram.tests",
        rootDirectory: root,
        storeURL: root.appendingPathComponent("Engram.store", isDirectory: false),
        queueDirectory: root.appendingPathComponent("queue", isDirectory: true),
        modelsDirectory: root.appendingPathComponent("Models", isDirectory: true),
        videosDirectory: root.appendingPathComponent("videos", isDirectory: true),
        retrievalIndexURL: root.appendingPathComponent("EngramRetrieval.sqlite", isDirectory: false),
        usesAppGroupContainer: false
    )
    try FileManager.default.createDirectory(at: locations.rootDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: locations.queueDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: locations.modelsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: locations.videosDirectory, withIntermediateDirectories: true)
    return locations
}

private actor AppShellRecordingVideoAnalyzer: VideoAnalyzing {
    private(set) var sources: [VideoSource] = []
    private(set) var stageCalls: [ClipState] = []

    func analyze(
        _ source: VideoSource,
        onStage: @Sendable (ClipState) async -> Void
    ) async throws -> Script {
        sources.append(source)
        for stage in [ClipState.transcribing, .scripting] {
            await onStage(stage)
            stageCalls.append(stage)
        }
        return appShellVideoScript(sourceID: source.id)
    }
}

private actor AppShellTestEmbeddingEngine: EmbeddingEngine {
    nonisolated let metadata = EmbeddingEngineMetadata(
        id: "app-shell-test-embedding",
        displayName: "AppShell Test Embedding",
        dimension: 8
    )

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map(Self.vector)
    }

    private nonisolated static func vector(for text: String) -> [Float] {
        var vector = Array(repeating: Float(0), count: 8)
        for scalar in text.lowercased().unicodeScalars where !scalar.properties.isWhitespace {
            let bucket = Int(scalar.value % UInt32(vector.count))
            vector[bucket] += 1
        }

        let magnitude = sqrt(vector.reduce(Double(0)) { total, value in
            total + Double(value * value)
        })
        guard magnitude > 0 else {
            return vector
        }
        return vector.map { Float(Double($0) / magnitude) }
    }
}

private func appShellVideoScript(sourceID: String) -> Script {
    Script(
        id: "script-\(sourceID)",
        videoSourceID: sourceID,
        title: "Raincoat Closeup",
        summary: "红色雨衣在夜市摊位前完成特写展示。",
        shots: [
            StoryboardShot(
                index: 0,
                startSeconds: 0,
                endSeconds: 4,
                narration: "旁白强调红色雨衣的防水细节。",
                visualDescription: "红色雨衣的袖口和拉链特写，雨滴在表面滚落。",
                pacingNote: "快慢结合"
            )
        ],
        createdAt: Date(timeIntervalSince1970: 1_800_000_600)
    )
}

private actor AppShellFixtureSnapshotDownloader: ModelSnapshotDownloading {
    private var calls = 0

    var callCount: Int {
        calls
    }

    func downloadSnapshot(
        for model: ModelIdentity,
        into downloadBase: URL,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        calls += 1

        let directory = model.id.split(separator: "/").reduce(
            downloadBase.appendingPathComponent("models", isDirectory: true)
        ) { url, component in
            url.appendingPathComponent(String(component), isDirectory: true)
        }
        try makeLocalModelFixture(at: directory)

        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 100
        progressHandler(progress)
        return directory
    }
}

private actor FakeEngine: LLMEngine {
    nonisolated let descriptor: EngineDescriptor

    init(id: String, displayName: String) {
        self.descriptor = EngineDescriptor(id: id, displayName: displayName, kind: .mlx)
    }

    func load(_ model: ModelIdentity) async throws {}

    func unload() async {}

    func generate(_ request: GenerationRequest) async -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(.stop, GenerationMetrics(
                firstTokenLatencyMillis: nil,
                tokensPerSecond: nil,
                outputTokenCount: 0
            )))
            continuation.finish()
        }
    }

    func countTokens(in text: String) async throws -> Int {
        text.count
    }
}

private final class FakeBackgroundScheduler: ClipDigestBackgroundScheduling, @unchecked Sendable {
    private(set) var registerCallCount = 0
    private(set) var submitCallCount = 0
    private var registeredHandler: (@Sendable () async -> Bool)?

    var hasRegisteredHandler: Bool {
        registeredHandler != nil
    }

    func register(handler: @escaping @Sendable () async -> Bool) -> Bool {
        registerCallCount += 1
        registeredHandler = handler
        return true
    }

    func submit() -> Bool {
        submitCallCount += 1
        return true
    }
}

private actor FakeRetriever: Retriever {
    private let results: [RetrievedChunk]

    init(results: [RetrievedChunk]) {
        self.results = results
    }

    func retrieve(question: String, topK: Int) async throws -> [RetrievedChunk] {
        Array(results.prefix(topK))
    }
}
