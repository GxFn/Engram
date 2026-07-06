import AppShell
import AskFeature
import ClipCore
import ClipDigest
import ClipPipeline
import EngineKit
import Foundation
import MemoryFeature
import ModelStore
import Persistence
import RAGCore
import SwiftData
import Testing

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

private func makeDefaults() -> UserDefaults {
    let suiteName = "EngramAppShellTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
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
