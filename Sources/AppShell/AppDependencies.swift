import AppGroupSupport
import AskFeature
import BenchFeature
import ClipDigest
import CloudVision
import CoreGraphics
import EngramLogging
import EngineKit
import ImageIO
import InsightFeature
import MemoryFeature
import MLXEngine
import ModelStore
import Observation
import Persistence
import RAGCore
import ScriptComposer
import ScriptCore
import ShotDetection
import StoryboardCore
import StoryboardExport
import SettingsFeature
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VideoUnderstanding

@MainActor
@Observable
public final class AppDependencies {
    private enum DefaultsKey {
        static let activeEngineID = "activeEngineID"
        static let activeModelID = "activeModelID"
        static let temperature = "generation.temperature"
        static let topP = "generation.topP"
        static let maxTokens = "generation.maxTokens"
        static let scriptParadigms = "scriptParadigms"
    }

    public let engines: [any LLMEngine]
    public var activeEngine: any LLMEngine
    public let modelStore: ModelStore
    public var activeModel: ModelIdentity
    public var generationConfig: GenerationConfig

    @ObservationIgnored public private(set) var clipDigestService: ClipDigestService?
    @ObservationIgnored public private(set) var retriever: (any Retriever)?
    @ObservationIgnored private let deviceCapability: DeviceCapability
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let clipDigestBackgroundScheduler: any ClipDigestBackgroundScheduling
    @ObservationIgnored private var clipNotificationObserver: ClipEnqueueNotificationObserver?
    // Shared so the 剪藏 and 拆解 tabs render the same store from one instance / one load.
    @ObservationIgnored private var cachedMemoryViewModel: MemoryViewModel?
    // The single in-flight digest, so overlapping triggers coalesce and the slow cloud VLM request
    // it may run is shielded from view-lifecycle cancellation (-999) via a detached task.
    @ObservationIgnored private var digestTask: Task<Void, Never>?
    // Debounces generation-parameter changes into one pipeline rebuild (sliders fire per tick).
    @ObservationIgnored private var generationConfigRebuildTask: Task<Void, Never>?
    // Retained so AI routing (云端 ↔ 本地) can be re-resolved live, without an app relaunch,
    // when the user changes the mode or cloud credentials in Settings.
    @ObservationIgnored private let modelContainer: ModelContainer?
    @ObservationIgnored private let appGroupLocations: AppGroupLocations?
    @ObservationIgnored private let retrievalEmbeddingEngine: (any EmbeddingEngine)?
    @ObservationIgnored private let videoAnalyzer: (any VideoAnalyzing)?
    @ObservationIgnored private let videoPipelineRuntime: VideoPipelineRuntime?
    @ObservationIgnored private let cloudAnalysisRuntime: CloudAnalysisRuntime?
    @ObservationIgnored private let cloudConsentCoordinator: CloudRunConsentCoordinator
    // Last AI config applied to the live graph; a change (incl. a model-id edit within 云端 mode)
    // triggers a rebuild so 问答/拆解 pick up new endpoints without a relaunch.
    @ObservationIgnored private var appliedAISignature: String

    public init(
        engines: [any LLMEngine] = [MLXEngine()],
        activeEngine: (any LLMEngine)? = nil,
        modelStore: ModelStore = ModelStore(),
        activeModel: ModelIdentity? = nil,
        generationConfig: GenerationConfig? = nil,
        deviceCapability: DeviceCapability = DeviceCapability(),
        defaults: UserDefaults? = .standard,
        modelContainer: ModelContainer? = nil,
        videoAnalyzer: (any VideoAnalyzing)? = nil,
        appGroupLocations: AppGroupLocations? = nil,
        retrievalEmbeddingEngine: (any EmbeddingEngine)? = nil,
        clipDigestService: ClipDigestService? = nil,
        retriever: (any Retriever)? = nil,
        clipDigestBackgroundScheduler: any ClipDigestBackgroundScheduling = ClipDigestBackgroundScheduler(),
        cloudAnalysisRuntime: CloudAnalysisRuntime? = nil,
        videoPipelineRuntime: VideoPipelineRuntime? = nil
    ) {
        let resolvedEngines = engines.isEmpty ? [MLXEngine()] : engines
        // Cloud mode makes the cloud engine the active text engine (and vision runs on cloud too);
        // otherwise fall back to the on-device engine/model resolution.
        let resolved = Self.resolveRouting(
            defaults: defaults,
            explicitEngine: activeEngine,
            explicitModel: activeModel,
            engines: resolvedEngines,
            deviceCapability: deviceCapability
        )
        let resolvedEngine = resolved.engine
        let resolvedModel = resolved.model
        let resolvedModelStore = modelStore
        let resolvedGenerationConfig = GenerationConfigBounds.clamped(
            generationConfig
                ?? Self.storedGenerationConfig(defaults: defaults)
                ?? .default
        )
        let resolvedVisionGenerator = CloudAIResolver.makeVisionGenerator(defaults: defaults)
        let resolvedConsentCoordinator = CloudRunConsentCoordinator()
        let resolvedRoutingSignature = CloudAIResolver.configSignature(defaults: defaults)
        let resolvedAnalysisConfiguration = CloudAIResolver.makeAnalysisConfiguration(
            defaults: defaults,
            requestConsent: { prompt in
                await resolvedConsentCoordinator.consume(
                    prompt,
                    routingSignature: resolvedRoutingSignature
                )
            }
        )
        let retrievalServices = modelContainer.flatMap {
            try? RetrievalAssembly.makeServices(
                modelContainer: $0,
                modelStore: resolvedModelStore,
                activeEngine: resolvedEngine,
                activeModel: resolvedModel,
                generationConfig: resolvedGenerationConfig,
                videoAnalyzer: videoAnalyzer,
                visionGenerator: resolvedVisionGenerator,
                // Generic JSON video jobs remain an injectable test/debug seam only. Saved
                // production settings always use the provider-specific analysis configuration.
                cloudVideoConfiguration: nil,
                cloudAnalysisConfiguration: resolvedAnalysisConfiguration,
                cloudAnalysisRuntime: cloudAnalysisRuntime,
                appGroupLocations: appGroupLocations,
                embeddingEngine: retrievalEmbeddingEngine,
                videoPipelineRuntime: videoPipelineRuntime
            )
        }

        self.engines = resolvedEngines
        self.activeEngine = resolvedEngine
        self.modelStore = resolvedModelStore
        self.activeModel = resolvedModel
        self.generationConfig = resolvedGenerationConfig
        self.clipDigestService = clipDigestService ?? retrievalServices?.clipDigestService
        self.retriever = retriever ?? retrievalServices?.retriever
        self.deviceCapability = deviceCapability
        self.defaults = defaults
        self.clipDigestBackgroundScheduler = clipDigestBackgroundScheduler
        self.modelContainer = modelContainer
        self.appGroupLocations = appGroupLocations
        self.retrievalEmbeddingEngine = retrievalEmbeddingEngine
        self.videoAnalyzer = videoAnalyzer
        self.videoPipelineRuntime = videoPipelineRuntime
        self.cloudAnalysisRuntime = cloudAnalysisRuntime
        self.cloudConsentCoordinator = resolvedConsentCoordinator
        self.appliedAISignature = resolvedRoutingSignature
    }

    /// Resolves the active text engine + model from the current settings: 云端 mode returns the
    /// cloud engine when its credentials are configured; otherwise the on-device engine/model.
    /// `explicitEngine`/`explicitModel` (used by tests and previews) take precedence over cloud.
    private static func resolveRouting(
        defaults: UserDefaults?,
        explicitEngine: (any LLMEngine)?,
        explicitModel: ModelIdentity?,
        engines: [any LLMEngine],
        deviceCapability: DeviceCapability
    ) -> (engine: any LLMEngine, model: ModelIdentity) {
        if explicitEngine == nil, let cloud = CloudAIResolver.makeLLMEngine(defaults: defaults) {
            return (cloud, CloudAIResolver.cloudModelIdentity)
        }
        let engine = explicitEngine
            ?? storedEngine(defaults: defaults, engines: engines)
            ?? engines[0]
        let model = explicitModel
            ?? storedModel(defaults: defaults)
            ?? deviceCapability.recommendedModel
        return (engine, model)
    }

    /// Identity of the current AI routing, used by the shell to re-create tab views when routing
    /// changes so each feature rebinds to the freshly resolved engine + services. Includes the
    /// cloud config signature so a model-endpoint edit (engine id stays "cloud") still re-creates.
    public var aiRoutingSignature: String {
        // Generation params are part of the routing identity: the digest pipeline bakes them into
        // its composers, so tabs keyed on this signature must rebind when the user tunes them.
        let config = "\(String(format: "%.2f", generationConfig.temperature))|\(String(format: "%.2f", generationConfig.topP))|\(generationConfig.maxTokens)"
        return "\(activeEngine.descriptor.id)|\(activeModel.id)|\(appliedAISignature)|\(config)"
    }

    /// Re-resolves the text engine, vision generator, and retrieval services from the current
    /// 云端/本地 settings so 问答 and 拆解 apply a mode/credential change without an app relaunch.
    /// Cheap no-op when the resolved text engine + model are unchanged.
    public func reloadAIRouting() {
        // Rebuild whenever any AI config changed — including a cloud model-id edit within 云端 mode,
        // where the engine id ("cloud") and model id stay constant but the endpoint differs.
        let signature = CloudAIResolver.configSignature(defaults: defaults)
        guard signature != appliedAISignature else {
            return
        }
        let previousSignature = appliedAISignature
        let previousEngine = activeEngine
        let previousModel = activeModel
        appliedAISignature = signature
        Task { await cloudConsentCoordinator.disarm() }

        let resolved = Self.resolveRouting(
            defaults: defaults,
            explicitEngine: nil,
            explicitModel: nil,
            engines: engines,
            deviceCapability: deviceCapability
        )
        activeEngine = resolved.engine
        activeModel = resolved.model

        // Rebuild retrieval services so digest/拆解 use the newly resolved vision generator, then
        // drop the shared MemoryViewModel cache so 剪藏/拆解 rebind to the fresh ClipDigestService.
        guard rebuildRetrievalServices() else {
            // Keep the previously working graph and leave this signature unapplied so the same
            // saved configuration can retry instead of silently pinning the stale services.
            appliedAISignature = previousSignature
            activeEngine = previousEngine
            activeModel = previousModel
            return
        }
    }

    /// Arms exactly one LAS run. The receipt is created only after the analyzer has probed the
    /// chosen asset and computed the exact role/fingerprint plan.
    public func authorizeNextCloudAnalysisRun() async {
        await cloudConsentCoordinator.arm(routingSignature: appliedAISignature)
    }

    /// Explicit Ark diagnostic using only a fixed text and an app-generated 4×4 JPEG. It records
    /// each role only after that role's real endpoint completed, without reading user media.
    private func probeArkCapabilities() async throws {
        let store = CloudSettingsStore(defaults: defaults)
        let settings = store.load()
        guard settings.ark.isConfigured,
              let baseURL = URL(string: settings.ark.baseURL),
              let apiKey = store.credential(.arkAPIKey), !apiKey.isEmpty
        else { throw VideoUnderstandingError.visionUnavailable("Ark diagnostic configuration is incomplete") }

        let engine = OpenAICompatibleLLMEngine(configuration: CloudLLMConfiguration(
            baseURL: baseURL,
            model: settings.ark.textModelID,
            apiKey: apiKey,
            timeout: 30
        ))
        do {
            var receivedText = false
            let stream = await engine.generate(GenerationRequest(
                messages: [ChatMessage(role: .user, content: "Reply with OK.")],
                config: GenerationConfig(temperature: 0, topP: 1, maxTokens: 8)
            ))
            for try await event in stream {
                if case .token(let value) = event,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    receivedText = true
                }
            }
            guard receivedText else {
                throw VideoUnderstandingError.visionUnavailable("Ark text diagnostic returned no content")
            }
            Self.recordArkCapability(.arkText, settings: settings, store: store)
        } catch {
            Self.invalidateArkCapabilityIfAuthenticationFailed(error, role: .arkText, store: store)
            throw VideoUnderstandingError.visionUnavailable(
                CloudErrorSanitizer.sanitize("Ark text diagnostic failed: \(Self.cloudErrorCode(error))")
            )
        }

        do {
            let generator = OpenAICompatibleVLMGenerator(configuration: CloudVLMConfiguration(
                baseURL: baseURL,
                model: settings.ark.frameModelID,
                apiKey: apiKey,
                timeout: 30
            ))
            let content = try await generator.generate(
                prompt: "Reply with OK for this synthetic diagnostic image.",
                frames: [SampledFrame(timestampSeconds: 0, jpegData: try Self.syntheticDiagnosticJPEG())],
                config: GenerationConfig(temperature: 0, topP: 1, maxTokens: 8)
            )
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VideoUnderstandingError.visionUnavailable("Ark frame diagnostic returned no content")
            }
            Self.recordArkCapability(.arkFrame, settings: settings, store: store)
        } catch {
            Self.invalidateArkCapabilityIfAuthenticationFailed(error, role: .arkFrame, store: store)
            throw VideoUnderstandingError.visionUnavailable(
                CloudErrorSanitizer.sanitize("Ark frame diagnostic failed: \(Self.cloudErrorCode(error))")
            )
        }
    }

    /// Explicit Settings diagnostic. Selecting a non-private sample and confirming the warning is
    /// the authority for this one probe; normal analysis remains blocked until these live-media
    /// snapshots exist and are fresh.
    private func probeLASCapabilities(fileURL: URL) async throws {
        let accessGranted = fileURL.startAccessingSecurityScopedResource()
        defer { if accessGranted { fileURL.stopAccessingSecurityScopedResource() } }
        let source = VideoSource(
            id: "las-diagnostic-\(UUID().uuidString)",
            localFileURL: fileURL,
            importedAt: Date()
        )
        let asset = try await AVFoundationVideoAssetProbe().probe(source)
        let frameCount = asset.frameCount ?? max(1, Int((asset.durationSeconds * asset.nominalFrameRate).rounded()))
        let graph = try ShotGraph(asset: asset, shots: [ShotSegment(
            id: ShotID(rawValue: "PROBE"),
            timeRange: MediaTimeRange(startSeconds: 0, endSeconds: asset.durationSeconds),
            frameRange: FrameRange(startFrame: 0, endFrameExclusive: frameCount),
            transitionIn: .start,
            transitionOut: .end,
            boundaryConfidence: 1,
            detectorEvidenceIDs: ["settings-live-media-probe"]
        )])
        guard let base = CloudAIResolver.makeAnalysisConfiguration(
            defaults: defaults,
            requestConsent: { prompt in
                CloudRunConsentReceipt(
                    runID: prompt.runID,
                    sourceFingerprint: prompt.sourceFingerprint,
                    planHash: prompt.planHash,
                    acceptedAt: Date(),
                    maximumBytes: prompt.byteCount,
                    maximumDurationSeconds: prompt.durationSeconds,
                    costAcceptance: prompt.costAcceptance
                )
            }
        ) else {
            throw VideoUnderstandingError.visionUnavailable("LAS diagnostic configuration is incomplete")
        }
        let diagnostic = CloudAIResolver.AnalysisConfiguration(
            requestedMode: .lasDeep,
            expectedFingerprints: base.expectedFingerprints,
            capabilitySnapshots: base.capabilitySnapshots,
            arkConfigured: false,
            region: base.region,
            lasAPIKey: base.lasAPIKey,
            stagingConfiguration: base.stagingConfiguration,
            stagingCredentials: base.stagingCredentials,
            maximumUploadBytes: base.maximumUploadBytes,
            credentialReferenceIDs: base.credentialReferenceIDs,
            requestConsent: base.requestConsent,
            invalidateCapability: base.invalidateCapability,
            recordCapability: base.recordCapability
        )
        let enricher = ConfiguredCloudAnalysisEnricher(
            configuration: diagnostic,
            runtime: cloudAnalysisRuntime ?? .live,
            allowsUnprobedDiagnostic: true
        )
        _ = try await enricher.enrich(
            source: source,
            asset: asset,
            graph: graph,
            resume: nil,
            checkpoint: { _ in }
        )
    }

    /// Rebuilds the digest/retrieval stack from the CURRENT engine/model/generation config. Shared
    /// by mode/credential changes (reloadAIRouting) and generation-parameter changes.
    @discardableResult
    private func rebuildRetrievalServices() -> Bool {
        let routingSignature = appliedAISignature
        guard let modelContainer else { return true }
        guard let services = try? RetrievalAssembly.makeServices(
                  modelContainer: modelContainer,
                  modelStore: modelStore,
                  activeEngine: activeEngine,
                  activeModel: activeModel,
                  generationConfig: generationConfig,
                  videoAnalyzer: videoAnalyzer,
                  visionGenerator: CloudAIResolver.makeVisionGenerator(defaults: defaults),
                  // Generic JSON video jobs remain an injectable test/debug seam only.
                  cloudVideoConfiguration: nil,
                  cloudAnalysisConfiguration: CloudAIResolver.makeAnalysisConfiguration(
                      defaults: defaults,
                      requestConsent: { [cloudConsentCoordinator] prompt in
                          await cloudConsentCoordinator.consume(
                              prompt,
                              routingSignature: routingSignature
                          )
                      }
                  ),
                  cloudAnalysisRuntime: cloudAnalysisRuntime,
                  appGroupLocations: appGroupLocations,
                  embeddingEngine: retrievalEmbeddingEngine,
                  videoPipelineRuntime: videoPipelineRuntime
              )
        else {
            return false
        }
        retriever = services.retriever
        clipDigestService = services.clipDigestService
        cachedMemoryViewModel = nil
        return true
    }

    public func selectEngine(id: String) {
        guard let engine = engines.first(where: { $0.descriptor.id == id }) else {
            return
        }

        activeEngine = engine
        defaults?.set(id, forKey: DefaultsKey.activeEngineID)
    }

    public func selectModel(_ model: ModelIdentity) {
        activeModel = model
        defaults?.set(model.id, forKey: DefaultsKey.activeModelID)
    }

    public func updateGenerationConfig(_ config: GenerationConfig) {
        generationConfig = GenerationConfigBounds.clamped(config)
        persistGenerationConfig()
        // The digest pipeline bakes generationConfig into its composers at construction, so a tune
        // used to be silent for 拆解 until relaunch. Debounced (sliders fire per tick — rebuilding
        // SQLite-backed services each tick would thrash) and deferred past any in-flight digest so
        // the service isn't swapped under an active run.
        generationConfigRebuildTask?.cancel()
        generationConfigRebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            if let digestTask = self.digestTask {
                await digestTask.value
            }
            guard !Task.isCancelled else { return }
            self.rebuildRetrievalServices()
        }
    }

    public func makeSettingsViewModel() -> SettingsViewModel {
        let store = modelStore
        let capability = deviceCapability
        let launchLineup = ModelCatalog.launchLineup

        let client = ModelManagementClient(
            refreshModels: {
                let downloadedModels = try await store.downloadedModels()
                let allModels = Self.uniqueModels(launchLineup + downloadedModels)

                var rows: [ManagedModel] = []
                for model in allModels {
                    let isDownloaded = try await store.isDownloaded(model)
                    let storageBytes = try await store.storageBytes(for: model)
                    rows.append(ManagedModel(
                        model: model,
                        isDownloaded: isDownloaded,
                        storageBytes: storageBytes,
                        canRunOnDevice: capability.canRun(model),
                        isRecommended: model.id == capability.recommendedModel.id
                    ))
                }

                return rows
            },
            downloadModel: { model, progressHandler in
                try await store.download(model) { progress in
                    progressHandler(ModelDownloadProgress(
                        completedUnitCount: progress.completedBytes,
                        totalUnitCount: progress.totalBytes
                    ))
                }
            },
            installLocalModel: { model, sourceURL in
                try await store.installLocalModel(model, from: sourceURL)
            },
            deleteModel: { model in
                try await store.delete(model)
            }
        )

        // UserDefaults is thread-safe; the compiler just can't prove it Sendable for these
        // @Sendable closures. The vision-backend client owns UserDefaults + Keychain access so
        // SettingsFeature never touches infrastructure directly.
        nonisolated(unsafe) let capturedDefaults = defaults
        let cloudSettings = CloudSettingsStore(defaults: capturedDefaults)
        let visionBackendClient = VisionBackendClient(
            load: { cloudSettings.load() },
            saveNonSecret: { [weak self] settings in
                cloudSettings.save(settings)
                Task { @MainActor in self?.reloadAIRouting() }
            },
            setCredential: { [weak self] slot, value in
                _ = cloudSettings.setCredential(slot, value: value)
                Task { @MainActor in self?.reloadAIRouting() }
            },
            loadCapabilities: {
                cloudSettings.loadCapabilitySnapshots().map { snapshot in
                    CloudCapabilityDisplay(
                        role: snapshot.role.rawValue,
                        status: snapshot.status.rawValue,
                        probeLevel: snapshot.probeLevel.rawValue,
                        lastProbedAt: snapshot.lastProbedAt,
                        expiresAt: snapshot.expiresAt,
                        maximumBytes: snapshot.limits.maximumBytes,
                        maximumDurationSeconds: snapshot.limits.maximumDurationSeconds
                    )
                }
            },
            probeLASCapabilities: { [weak self] url in
                guard let self else { return }
                try await self.probeLASCapabilities(fileURL: url)
            },
            probeArkCapabilities: { [weak self] in
                guard let self else { return }
                try await self.probeArkCapabilities()
            },
            authorizeNextCloudRun: { [weak self] in
                await self?.authorizeNextCloudAnalysisRun()
            }
        )

        // 当前生效 panel: per-role (语言/视觉/检索) effective backend, resolved the same way the
        // pipeline resolves it — cloud only when the config is complete, with download/memory state
        // for the on-device fallbacks.
        nonisolated(unsafe) let rolesDefaults = defaults
        let rolesCapability = deviceCapability
        let loadActiveRoles: @Sendable () async -> ActiveAIRoles? = {
            let settingsStore = CloudSettingsStore(defaults: rolesDefaults)
            let settings = settingsStore.load()
            let text: String
            let vision: String
            switch settings.requestedMode {
            case .local:
                let prefix = "本地 · "
                let localText = Self.storedModel(defaults: rolesDefaults) ?? rolesCapability.recommendedModel
                let textDownloaded = (try? await store.isDownloaded(localText)) ?? false
                text = prefix + Self.shortModelName(localText.id) + (textDownloaded ? "" : "（未下载）")

                let vl = ModelCatalog.qwen3VL_4B_4bit
                if !rolesCapability.canRun(vl) {
                    vision = "不可用（本机内存不足，建议云端）"
                } else {
                    let vlDownloaded = (try? await store.isDownloaded(vl)) ?? false
                    vision = prefix + Self.shortModelName(vl.id) + (vlDownloaded ? "" : "（未下载）")
                }
            case .arkStandard:
                if settings.ark.isConfigured {
                    text = "Ark Standard · \(settings.ark.textModelID)"
                    vision = "Ark 代表帧 · \(settings.ark.frameModelID)"
                } else {
                    text = "不可用 · 缺少 arkText"
                    vision = "不可用 · 缺少 arkFrame"
                }
            case .lasDeep, .hybridMaximum:
                let requested: CloudVision.CloudAnalysisRequestedMode = settings.requestedMode == .lasDeep
                    ? .lasDeep : .hybridMaximum
                let decision = CloudAnalysisPlanner.resolve(
                    requested: requested,
                    snapshots: settingsStore.loadCapabilitySnapshots(),
                    expectedFingerprints: settingsStore.configurationFingerprints(),
                    consent: nil,
                    now: Date()
                )
                let blocked = (decision.missingRoles + decision.staleRoles).map(\.rawValue).joined(separator: ",")
                if blocked.isEmpty {
                    text = settings.requestedMode == .hybridMaximum
                        ? "LAS 剧本 + Ark 文本 · 等待单次同意"
                        : "LAS 剧本 · 等待单次同意"
                    vision = settings.requestedMode == .hybridMaximum
                        ? "LAS Deep + Ark 低置信精修 · 等待单次同意"
                        : "LAS Deep · 等待单次同意"
                } else {
                    text = "不可用 · \(blocked)"
                    vision = "不可用 · \(blocked)"
                }
            }
            return ActiveAIRoles(
                text: text,
                vision: vision,
                retrieval: "端侧 · Apple 语义向量"
            )
        }

        let modelsRoot = store.modelDirectoryRoot
        let loadStorage: @Sendable () async -> StorageSummary? = {
            let locations = try? EngramAppGroup.locations()
            return await Task.detached(priority: .utility) {
                StorageSummary(
                    videoBytes: Self.directoryBytes(locations?.videosDirectory),
                    modelBytes: Self.directoryBytes(modelsRoot),
                    indexBytes: Self.sqliteFamilyBytes(locations?.retrievalIndexURL)
                )
            }.value
        }

        return SettingsViewModel(
            engines: engines.map {
                SettingsEngineOption(
                    id: $0.descriptor.id,
                    displayName: $0.descriptor.displayName,
                    kind: $0.descriptor.kind
                )
            },
            selectedModelID: activeModel.id,
            selectedEngineID: activeEngine.descriptor.id,
            generationConfig: generationConfig,
            physicalMemoryBytes: deviceCapability.physicalMemoryBytes,
            recommendedModelID: deviceCapability.recommendedModel.id,
            client: client,
            visionBackendClient: visionBackendClient,
            loadActiveRoles: loadActiveRoles,
            loadStorage: loadStorage,
            applyActiveModel: { [weak self] model in
                self?.selectModel(model)
            },
            applyActiveEngine: { [weak self] engineID in
                self?.selectEngine(id: engineID)
            },
            applyGenerationConfig: { [weak self] config in
                self?.updateGenerationConfig(config)
            }
        )
    }

    public func makeMemoryViewModel() -> MemoryViewModel {
        if let cachedMemoryViewModel {
            return cachedMemoryViewModel
        }

        let viewModel: MemoryViewModel
        if let clipDigestService {
            viewModel = MemoryViewModel(client: MemoryClient(
                loadItems: {
                    let snapshots = try await clipDigestService.memorySnapshots()
                    return snapshots.map(Self.memoryClip(from:))
                },
                digestPending: { [weak self] in
                    // Shielded + coalesced so a pull-to-refresh release or navigation can't cancel
                    // an in-flight cloud digest (-999); routed through the owning dependencies.
                    await self?.digestPendingClips()
                },
                retryClip: { id in
                    try await clipDigestService.retryFailedClip(id: id)
                },
                importVideo: { url in
                    try await clipDigestService.importVideo(from: url)
                },
                addClip: { input in
                    switch input {
                    case let .text(text):
                        try await clipDigestService.capture(.text(text))
                    case let .url(url):
                        try await clipDigestService.capture(.url(url))
                    }
                },
                deleteClip: { id in
                    try await clipDigestService.deleteClip(id: id)
                },
                editClip: { id, text in
                    try await clipDigestService.updateClipText(id: id, text: text)
                },
                updateScript: { id, transform in
                    try await clipDigestService.updateScript(id: id, transform: transform)
                },
                reanalyzeScript: { [refinerEngine = activeEngine, refinerModel = activeModel] id in
                    // Re-derives 爆点结构/标题/摘要 from the corrected 台词+字幕+用户背景 via the active
                    // text engine (cloud or on-device) — a cheap text call, no video re-processing.
                    let snapshots = try await clipDigestService.memorySnapshots()
                    guard let snapshot = snapshots.first(where: { $0.id == id }),
                          let script = ScriptCoding.decode(json: snapshot.scriptJSON) else {
                        throw MemoryClientError.editingUnavailable
                    }
                    let refiner = ScriptAnalysisRefiner(engine: refinerEngine, model: refinerModel)
                    let refined = try await refiner.refine(script)
                    return try await clipDigestService.updateScript(id: id) { _ in refined }
                },
                exportStoryboard: { id in
                    let snapshots = try await clipDigestService.memorySnapshots()
                    guard let snapshot = snapshots.first(where: { $0.id == id }),
                          let json = snapshot.storyboardJSON,
                          let data = json.data(using: .utf8),
                          let document = try? JSONDecoder().decode(StoryboardDocumentV2.self, from: data),
                          let sourceURL = snapshot.url
                    else { throw MemoryClientError.exportUnavailable }
                    let keyframes = try await AVFoundationShotKeyframeSelector().select(
                        in: document.shotGraph,
                        sourceURL: sourceURL
                    )
                    let root = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Engram-\(id)-storyboard-export", isDirectory: true)
                    if FileManager.default.fileExists(atPath: root.path) {
                        try FileManager.default.removeItem(at: root)
                    }
                    let bundle = try StoryboardExporter().export(document, keyframes: keyframes, to: root)
                    let validation = StoryboardExportValidator.validate(bundle, document: document)
                    guard validation.isValid else { throw MemoryClientError.exportUnavailable }
                    return bundle.artifacts.map(\.url)
                },
                editStoryboardShot: { id, index, command in
                    let receipt: StoryboardEditReceipt
                    if command == .undo {
                        receipt = try await clipDigestService.undoStoryboard(id: id)
                    } else if command == .reanalyze {
                        receipt = try await clipDigestService.reanalyzeStoryboard(id: id, shotIndex: index)
                    } else {
                        receipt = try await clipDigestService.applyStoryboardEdit(id: id) { document in
                            guard document.shotGraph.shots.indices.contains(index) else {
                                throw MemoryClientError.editingUnavailable
                            }
                            let shotID = document.shotGraph.shots[index].id
                            switch command {
                            case let .split(atSeconds):
                                return try StoryboardEditor.split(document, shotID: shotID, atSeconds: atSeconds)
                            case .mergeWithNext:
                                guard document.shotGraph.shots.indices.contains(index + 1) else {
                                    throw MemoryClientError.editingUnavailable
                                }
                                let nextID = document.shotGraph.shots[index + 1].id
                                return try StoryboardEditor.merge(document, first: shotID, second: nextID)
                            case let .editDialogue(value):
                                return try StoryboardEditor.editPlanField(
                                    document,
                                    shotID: shotID,
                                    field: .dialogueOrVO,
                                    value: value,
                                    lock: true
                                )
                            case let .moveEndBoundary(toSeconds):
                                return try StoryboardEditor.moveBoundary(document, after: shotID, toSeconds: toSeconds)
                            case let .editPlan(values):
                                return try StoryboardEditor.editPlanFields(
                                    document,
                                    shotID: shotID,
                                    values: values.domainValues,
                                    lock: true
                                )
                            case let .editObservedFact(field, value):
                                return try StoryboardEditor.editObservedFact(
                                    document,
                                    shotID: shotID,
                                    field: field,
                                    value: value
                                )
                            case let .selectRepresentativeFrames(refs):
                                return try StoryboardEditor.selectRepresentativeFrames(
                                    document,
                                    shotID: shotID,
                                    artifactRefs: refs
                                )
                            case .undo, .reanalyze:
                                throw MemoryClientError.editingUnavailable
                            }
                        }
                    }
                    return Self.storyboardEditPresentation(receipt)
                }
            ))
        } else {
            viewModel = MemoryViewModel()
        }

        cachedMemoryViewModel = viewModel
        return viewModel
    }

    public func makeAskViewModel() -> AskViewModel {
        // Resolves clipID -> isVideo so 问答 can scope answers to 剪藏 / 拆解 on demand.
        let clipKinds: (@Sendable () async -> [String: Bool])?
        if let service = clipDigestService {
            clipKinds = {
                let snapshots = (try? await service.memorySnapshots()) ?? []
                return Dictionary(
                    snapshots.map { ($0.id, $0.isVideo) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        } else {
            clipKinds = nil
        }
        // 聚焦订正: the chat renders the focused breakdown's facts into its system prompt, and a
        // model-emitted <engram-edit> block is decoded + applied through the same write-back path
        // as manual editing (updateScript → re-encode → re-index), then the memory tabs refresh.
        let focusedFacts: (@Sendable (String) async -> String?)?
        let applyEdit: (@Sendable (String, String) async throws -> String)?
        if let service = clipDigestService {
            focusedFacts = { clipID in
                let snapshots = (try? await service.memorySnapshots()) ?? []
                guard let snapshot = snapshots.first(where: { $0.id == clipID }),
                      let script = ScriptCoding.decode(json: snapshot.scriptJSON) else {
                    return nil
                }
                return BreakdownFactsRendering.facts(for: script)
            }
            applyEdit = { [weak self] clipID, rawJSON in
                let plan = try BreakdownEditPlan.decode(fromJSON: rawJSON)
                guard plan.isSubstantive else {
                    throw BreakdownEditError.nothingToApply
                }
                _ = try await service.updateScript(id: clipID) { plan.applied(to: $0) }
                await self?.cachedMemoryViewModel?.refresh()
                return plan.note ?? "已更新拆解内容"
            }
        } else {
            focusedFacts = nil
            applyEdit = nil
        }

        return AskViewModel(
            engine: activeEngine,
            model: activeModel,
            generationConfig: generationConfig,
            retriever: retriever,
            clipKinds: clipKinds,
            focusedFactsProvider: focusedFacts,
            applyEdit: applyEdit
        )
    }

    public func makeInsightViewModel() -> InsightViewModel {
        // 洞察 works on 分镜剧本 (video breakdowns). Breakdowns are derived live from scriptJSON
        // (single source of truth); paradigms persist in UserDefaults. Distill/apply run on the
        // active LLM engine over a compact structured summary (not raw video) — cheap.
        let service = clipDigestService
        nonisolated(unsafe) let capturedDefaults = defaults
        let composer = ScriptParadigmComposer(engine: activeEngine, model: activeModel)

        let client = InsightClient(
            loadBreakdowns: {
                guard let service else {
                    return []
                }
                let snapshots = (try? await service.memorySnapshots()) ?? []
                var items: [BreakdownItem] = []
                for snapshot in snapshots where snapshot.isVideo {
                    guard let script = ScriptCoding.decode(json: snapshot.scriptJSON) else {
                        continue
                    }
                    items.append(BreakdownItem(
                        id: snapshot.id,
                        title: Self.preferredTitle(from: snapshot),
                        summary: script.summary,
                        createdAt: snapshot.createdAt
                    ))
                }
                return items.sorted { $0.createdAt > $1.createdAt }
            },
            generateParadigm: { clipIDs in
                guard let service else {
                    return nil
                }
                let snapshots = (try? await service.memorySnapshots()) ?? []
                let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                var sources: [ParadigmSource] = []
                for id in clipIDs {
                    guard let snapshot = byID[id],
                          let script = ScriptCoding.decode(json: snapshot.scriptJSON)
                    else {
                        continue
                    }
                    sources.append(ParadigmSource.from(clipID: id, title: Self.preferredTitle(from: snapshot), script: script))
                }
                return (try? await composer.compose(sources: sources)) ?? nil
            },
            loadParadigms: {
                Self.storedParadigms(capturedDefaults, key: DefaultsKey.scriptParadigms)
            },
            saveParadigm: { paradigm in
                var paradigms = Self.storedParadigms(capturedDefaults, key: DefaultsKey.scriptParadigms)
                paradigms.removeAll { $0.id == paradigm.id }
                paradigms.insert(paradigm, at: 0)
                if let data = try? JSONEncoder().encode(paradigms) {
                    capturedDefaults?.set(data, forKey: DefaultsKey.scriptParadigms)
                }
            },
            deleteParadigm: { id in
                var paradigms = Self.storedParadigms(capturedDefaults, key: DefaultsKey.scriptParadigms)
                paradigms.removeAll { $0.id == id }
                if let data = try? JSONEncoder().encode(paradigms) {
                    capturedDefaults?.set(data, forKey: DefaultsKey.scriptParadigms)
                }
            },
            applyParadigm: { paradigm, topic in
                (try? await composer.apply(paradigm: paradigm, topic: topic)) ?? nil
            }
        )
        return InsightViewModel(client: client)
    }

    private nonisolated static func storedParadigms(_ defaults: UserDefaults?, key: String) -> [ScriptParadigm] {
        guard let data = defaults?.data(forKey: key),
              let paradigms = try? JSONDecoder().decode([ScriptParadigm].self, from: data)
        else {
            return []
        }
        return paradigms
    }

    public func makeBenchViewModel() -> BenchViewModel {
        BenchViewModel(
            engine: activeEngine,
            model: activeModel,
            generationConfig: generationConfig,
            retrievalEvalRunner: try? RetrievalEvalRunner.bundledFixture()
        )
    }

    public nonisolated static func memoryNavigationTarget(for citation: CitationRef) -> MemoryNavigationTarget {
        MemoryNavigationTarget(clipID: citation.clipID, chunkID: citation.chunkID)
    }

    public func configureClipDigestTriggers() {
        guard let clipDigestService else {
            return
        }

        if clipNotificationObserver == nil {
            let observer = ClipEnqueueNotificationObserver { [weak self] in
                // Route through the coalesced/shielded path: firing directly during a manual refresh
                // ran a SECOND digest over the same queue — duplicate VLM cost and a spurious
                // pending-file-missing error for the loser. (BG stays direct: folding it into the
                // detached shield would fight OS suspension semantics.)
                Task { @MainActor in
                    await self?.digestPendingClips()
                }
            }
            observer.start()
            clipNotificationObserver = observer
        }

        _ = clipDigestBackgroundScheduler.register {
            do {
                try await clipDigestService.digestPending()
                return true
            } catch {
                Log.clip.error("BGProcessing digest failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
    }

    public func digestPendingClips() async {
        // Coalesce overlapping triggers (launch .task, foreground, enqueue notification, manual
        // refresh) and shield the digest from view-lifecycle cancellation: its video path makes a
        // slow cloud VLM request that a pull-to-refresh release / navigation / scene change would
        // otherwise abort mid-flight as NSURLErrorCancelled (-999), silently degrading 拆解 to
        // transcript-only. A detached task does not inherit the caller's cancellation.
        if let digestTask {
            await digestTask.value
            return
        }
        guard let clipDigestService else {
            return
        }
        let task = Task.detached(priority: .utility) {
            do {
                try await clipDigestService.digestPending()
            } catch {
                Log.clip.error("Digest failed: \(String(describing: error), privacy: .public)")
            }
        }
        digestTask = task
        await task.value
        digestTask = nil
    }

    public func scheduleClipDigest() {
        _ = clipDigestBackgroundScheduler.submit()
    }

    private func persistGenerationConfig() {
        defaults?.set(generationConfig.temperature, forKey: DefaultsKey.temperature)
        defaults?.set(generationConfig.topP, forKey: DefaultsKey.topP)
        defaults?.set(generationConfig.maxTokens, forKey: DefaultsKey.maxTokens)
    }

    private static func storedEngine(
        defaults: UserDefaults?,
        engines: [any LLMEngine]
    ) -> (any LLMEngine)? {
        guard let id = defaults?.string(forKey: DefaultsKey.activeEngineID) else {
            return nil
        }

        return engines.first { $0.descriptor.id == id }
    }

    private nonisolated static func storedModel(defaults: UserDefaults?) -> ModelIdentity? {
        guard let id = defaults?.string(forKey: DefaultsKey.activeModelID) else {
            return nil
        }

        return ModelCatalog.launchLineup.first { $0.id == id }
    }

    private static func storedGenerationConfig(defaults: UserDefaults?) -> GenerationConfig? {
        guard let defaults,
              defaults.object(forKey: DefaultsKey.temperature) != nil,
              defaults.object(forKey: DefaultsKey.topP) != nil,
              defaults.object(forKey: DefaultsKey.maxTokens) != nil
        else {
            return nil
        }

        return GenerationConfigBounds.clamped(GenerationConfig(
            temperature: defaults.double(forKey: DefaultsKey.temperature),
            topP: defaults.double(forKey: DefaultsKey.topP),
            maxTokens: defaults.integer(forKey: DefaultsKey.maxTokens)
        ))
    }

    private nonisolated static func uniqueModels(_ models: [ModelIdentity]) -> [ModelIdentity] {
        var seenIDs = Set<String>()
        var uniqueModels: [ModelIdentity] = []

        for model in models where !seenIDs.contains(model.id) {
            seenIDs.insert(model.id)
            uniqueModels.append(model)
        }

        return uniqueModels
    }

    private nonisolated static func memoryClip(from snapshot: ClipRecordSnapshot) -> MemoryClip {
        MemoryClip(
            id: snapshot.id,
            title: memoryTitle(from: snapshot),
            sourceURL: snapshot.url,
            note: snapshot.note,
            bodyText: snapshot.bodyText,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            state: snapshot.state,
            failureReason: snapshot.failureReason,
            failureRetryable: snapshot.failureRetryable,
            indexPreview: snapshot.indexPreview,
            scriptJSON: snapshot.scriptJSON,
            storyboardJSON: snapshot.storyboardJSON,
            activeRunID: snapshot.activeRunID,
            qualityStatusRaw: snapshot.qualityStatusRaw,
            sourceKind: snapshot.sourceKind
        )
    }

    private nonisolated static func storyboardEditPresentation(
        _ receipt: StoryboardEditReceipt
    ) -> StoryboardEditPresentation {
        let remap = receipt.remap.mapping
            .sorted { $0.key < $1.key }
            .map { "\($0.key.rawValue)→\($0.value.map(\.rawValue).joined(separator: "+"))" }
            .joined(separator: ", ")
        return StoryboardEditPresentation(
            script: receipt.legacy,
            document: receipt.document,
            changedShotIDs: receipt.diff.changedShotIDs.map(\.rawValue),
            changedFields: receipt.diff.changedFields.map(\.rawValue).sorted(),
            invalidatedStages: receipt.partialRerun.invalidatedStages.map(\.rawValue),
            remapSummary: remap.isEmpty ? nil : remap
        )
    }

    private nonisolated static func memoryTitle(from snapshot: ClipRecordSnapshot) -> String {
        preferredTitle(from: snapshot)
    }

    private static func recordArkCapability(
        _ role: CloudProviderRole,
        settings: VisionBackendSettings,
        store: CloudSettingsStore
    ) {
        guard let fingerprint = store.configurationFingerprints()[role] else { return }
        let now = Date()
        let modelID = role == .arkText ? settings.ark.textModelID : settings.ark.frameModelID
        store.saveCapabilitySnapshot(CloudRoleCapabilitySnapshot(
            role: role,
            providerKind: .volcengineArk,
            profileID: "ark-\(URL(string: settings.ark.baseURL)?.host ?? "configured")-\(modelID)",
            configurationFingerprint: fingerprint,
            credentialScheme: .apiKey,
            credentialReferenceID: VisionBackendKeychainAccount.arkAPIKey,
            probeLevel: .liveMedia,
            status: .available,
            observedCapabilities: [role.rawValue],
            acceptedMediaKinds: role == .arkFrame ? [.imageURL] : [],
            limits: CloudObservedLimits(),
            supportsAsync: false,
            supportsIdempotency: false,
            supportsCancellation: true,
            reportsUsage: false,
            lastProbedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            officialContractRevision: "las-first-2026-07-13-v1",
            sanitizedEvidenceCode: "live-synthetic-ark-request-completed"
        ))
    }

    private static func invalidateArkCapabilityIfAuthenticationFailed(
        _ error: Error,
        role: CloudProviderRole,
        store: CloudSettingsStore
    ) {
        let value = String(describing: error)
        if value.contains("401") { store.invalidateCapabilitySnapshot(role: role, httpStatus: 401) }
        if value.contains("403") { store.invalidateCapabilitySnapshot(role: role, httpStatus: 403) }
    }

    private static func cloudErrorCode(_ error: Error) -> String {
        switch error {
        case CloudVLMError.missingAPIKey: "missing-api-key"
        case CloudVLMError.invalidResponse: "invalid-response"
        case CloudVLMError.statusCode(let status, _): "http-\(status)"
        case CloudVLMError.emptyContent: "empty-content"
        case CloudVLMError.decodingFailed: "decoding-failed"
        case is CancellationError: "cancelled"
        default: CloudErrorSanitizer.sanitize(String(describing: error))
        }
    }

    private static func syntheticDiagnosticJPEG() throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw VideoUnderstandingError.visionUnavailable("synthetic diagnostic image unavailable") }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let image = context.makeImage() else {
            throw VideoUnderstandingError.visionUnavailable("synthetic diagnostic image unavailable")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw VideoUnderstandingError.visionUnavailable("synthetic diagnostic image unavailable") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VideoUnderstandingError.visionUnavailable("synthetic diagnostic image unavailable")
        }
        return data as Data
    }

    nonisolated static func shortModelName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Total on-disk size of a directory tree (0 for nil/missing paths).
    nonisolated static func directoryBytes(_ url: URL?) -> Int64 {
        guard let url else { return 0 }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// Size of an SQLite database including its -wal/-shm siblings (matched by filename prefix).
    nonisolated static func sqliteFamilyBytes(_ databaseURL: URL?) -> Int64 {
        guard let databaseURL else { return 0 }
        let parent = databaseURL.deletingLastPathComponent()
        let baseName = databaseURL.lastPathComponent
        guard let siblings = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return siblings
            .filter { $0.lastPathComponent.hasPrefix(baseName) }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(Int64(0)) { $0 + Int64($1) }
    }

    /// Meaningful display title: a stored non-UUID title wins; a UUID import name (PHPicker temp
    /// filenames) defers to the breakdown's AI title; then web host / body preview.
    nonisolated static func preferredTitle(from snapshot: ClipRecordSnapshot) -> String {
        let stored = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isAutoName = UUID(uuidString: stored) != nil
        if !stored.isEmpty, !isAutoName {
            return stored
        }
        if let scriptTitle = ScriptCoding.decode(json: snapshot.scriptJSON)?.title
            .trimmingCharacters(in: .whitespacesAndNewlines), !scriptTitle.isEmpty {
            return scriptTitle
        }
        if !stored.isEmpty {
            return stored
        }
        if let host = snapshot.url?.host(), !host.isEmpty {
            return host
        }
        if let bodyText = snapshot.bodyText?.trimmingCharacters(in: .whitespacesAndNewlines), !bodyText.isEmpty {
            return String(bodyText.prefix(48))
        }
        return "未命名"
    }
}

private struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies? = nil
}

public extension EnvironmentValues {
    var deps: AppDependencies? {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
}
