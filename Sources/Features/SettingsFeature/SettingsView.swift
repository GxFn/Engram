import SwiftUI
import UniformTypeIdentifiers

public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case current
    case local
    case ark
    case las

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .current: "当前生效"
        case .local: "Local"
        case .ark: "Ark"
        case .las: "LAS"
        }
    }

    var subtitle: String {
        switch self {
        case .current: "请求模式、实际角色与生成参数"
        case .local: "设备、本地模型与存储"
        case .ark: "文本与逐镜画面"
        case .las: "整视频、增强 ASR 与 TOS 暂存"
        }
    }

    var systemImage: String {
        switch self {
        case .current: "checkmark.circle"
        case .local: "desktopcomputer"
        case .ark: "cloud"
        case .las: "film.stack"
        }
    }

    var routeAccessibilityID: String {
        switch self {
        case .current: "settings.route.current"
        case .local: "settings.route.local"
        case .ark: "settings.route.ark"
        case .las: "settings.route.las"
        }
    }

    var screenAccessibilityID: String {
        switch self {
        case .current: "settings.screen.current"
        case .local: "settings.screen.local"
        case .ark: "settings.screen.ark"
        case .las: "settings.screen.las"
        }
    }
}

public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var importTarget: ManagedModel?
    @State private var isShowingModelImporter = false
    @State private var isShowingLASProbeImporter = false
    @State private var pendingLASProbeURL: URL?
    @State private var isConfirmingLASProbe = false
    @State private var cloudKeyInput = ""
    @State private var lasKeyInput = ""
    @State private var tosAccessKeyInput = ""
    @State private var tosSecretKeyInput = ""
    @State private var tosSecurityTokenInput = ""

    public init(viewModel: SettingsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        List {
            Section("配置") {
                ForEach(SettingsPane.allCases) { pane in
                    NavigationLink {
                        paneDestination(pane)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pane.title)
                                Text(pane.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: pane.systemImage)
                        }
                    }
                    .accessibilityIdentifier(pane.routeAccessibilityID)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section("最近错误") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .task { await viewModel.refresh() }
        .refreshable { await viewModel.refresh() }
        .fileImporter(
            isPresented: $isShowingModelImporter,
            allowedContentTypes: [.folder]
        ) { result in
            let target = importTarget
            importTarget = nil

            guard let target, case .success(let url) = result else {
                return
            }

            Task {
                await viewModel.installLocalModel(target, from: url)
            }
        }
        .fileImporter(
            isPresented: $isShowingLASProbeImporter,
            allowedContentTypes: [.movie]
        ) { result in
            guard case .success(let url) = result else { return }
            pendingLASProbeURL = url
            isConfirmingLASProbe = true
        }
        .confirmationDialog(
            "运行真实 LAS/TOS 探测？",
            isPresented: $isConfirmingLASProbe,
            titleVisibility: .visible
        ) {
            Button("上传并运行四个算子（可能收费）", role: .destructive) {
                guard let url = pendingLASProbeURL else { return }
                pendingLASProbeURL = nil
                Task { await viewModel.probeLASCapabilities(using: url) }
            }
            Button("取消", role: .cancel) { pendingLASProbeURL = nil }
        } message: {
            Text("仅选择非私密小视频。文件会流式暂存到你的 TOS，并提交视频分镜、精细理解、剧本生成和增强 ASR；费用未知且可能收费，结束后会立即尝试删除暂存对象。")
        }
        .navigationTitle("设置")
    }

    @ViewBuilder
    private func paneDestination(_ pane: SettingsPane) -> some View {
        Form {
            switch pane {
            case .current:
                modeSection
                activeRolesSection
                generationSection
            case .local:
                deviceSection
                modelGroup(.language)
                modelGroup(.vision)
                modelGroup(.retrieval)
                storageSection
            case .ark:
                arkSection
            case .las:
                lasSection
            }

            if let errorMessage = viewModel.errorMessage {
                Section("最近错误") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(pane.title)
        .accessibilityIdentifier(pane.screenAccessibilityID)
        .refreshable { await viewModel.refresh() }
    }

    private var modeSection: some View {
        Section {
            Picker("请求模式", selection: requestedModeBinding) {
                ForEach(CloudAnalysisRequestedMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Text("Local 零上传；Ark Standard 只发送文本和代表帧；LAS Deep 会在真实探测与单次同意后上传一份原视频；LAS + Ark 仅把低置信镜头交给 Ark 精修。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("AI 模式")
        }
    }

    private var arkSection: some View {
        Section("Ark · 文本与逐镜画面") {
            TextField("Base URL", text: cloudBaseURLBinding)
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("文本模型 ID", text: cloudTextModelBinding)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("视觉模型 ID", text: cloudModelBinding)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            HStack {
                SecureField(
                    viewModel.visionBackend.hasCloudKey ? "API Key（已保存，可覆盖）" : "API Key",
                    text: $cloudKeyInput
                )
                Button("保存") {
                    viewModel.setCloudAPIKey(cloudKeyInput)
                    cloudKeyInput = ""
                }
                .disabled(cloudKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if viewModel.cloudConfigIncomplete {
                Label("Ark 配置不完整：Ark Standard/Hybrid 不可执行；请补全或显式选择 Local/LAS Deep。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button {
                Task { await viewModel.probeArkCapabilities() }
            } label: {
                if viewModel.isProbingArk {
                    ProgressView()
                } else {
                    Label("探测 Ark 文本与代表帧", systemImage: "waveform.path.ecg")
                }
            }
            .disabled(viewModel.isProbingArk || viewModel.cloudConfigIncomplete)
            Text("探测只发送固定短文本和 Engram 生成的 4×4 合成图，不读取用户媒体；它会发起两次真实请求，费用未知且可能收费。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(viewModel.cloudCapabilities.filter { $0.role.hasPrefix("ark") }) { capability in
                LabeledContent(capability.role, value: "\(capability.status) · \(capability.probeLevel)")
            }
            Text("Ark API Key 与 LAS/TOS 凭据使用独立 Keychain 项。Ark 不代表整片视频、LAS 或云 ASR 能力。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lasSection: some View {
        Section("LAS · 独立深度视频") {
            Toggle("启用 LAS", isOn: lasEnabledBinding)
            LabeledContent("Service", value: "cn-beijing · \(viewModel.visionBackend.las.operatorBaseURL.host ?? "")")
            LabeledContent("Video storyboard", value: viewModel.visionBackend.las.videoStoryboardOperatorID)
            LabeledContent("Video fine understanding", value: viewModel.visionBackend.las.videoFineUnderstandingOperatorID)
            LabeledContent("Script generation", value: viewModel.visionBackend.las.scriptGenerationOperatorID)
            LabeledContent("Doubao enhanced ASR", value: viewModel.visionBackend.las.enhancedASROperatorID)
            HStack {
                SecureField(
                    viewModel.visionBackend.las.hasAPIKey ? "LAS API Key（已保存，可覆盖）" : "LAS API Key",
                    text: $lasKeyInput
                )
                Button("保存") {
                    viewModel.setLASAPIKey(lasKeyInput)
                    lasKeyInput = ""
                }
                .disabled(lasKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            TextField("TOS bucket", text: tosBucketBinding)
                .autocorrectionDisabled()
            TextField("Engram object prefix", text: tosPrefixBinding)
                .autocorrectionDisabled()
            TextField("临时 STS 引用 ID", text: tosReferenceBinding)
                .autocorrectionDisabled()
            SecureField("临时 AccessKey ID", text: $tosAccessKeyInput)
            SecureField("临时 SecretAccessKey", text: $tosSecretKeyInput)
            SecureField("临时 SecurityToken", text: $tosSecurityTokenInput)
            DatePicker("STS 到期", selection: tosExpiryBinding, displayedComponents: [.date, .hourAndMinute])
            Button("保存临时 STS 凭据") {
                viewModel.setTemporaryTOSCredentials(
                    accessKeyID: tosAccessKeyInput,
                    secretAccessKey: tosSecretKeyInput,
                    securityToken: tosSecurityTokenInput,
                    expiresAt: tosExpiryBinding.wrappedValue
                )
                tosAccessKeyInput = ""
                tosSecretKeyInput = ""
                tosSecurityTokenInput = ""
            }
            .disabled(
                tosAccessKeyInput.isEmpty || tosSecretKeyInput.isEmpty || tosSecurityTokenInput.isEmpty
            )
            Stepper(value: uploadLimitBinding, in: 10...20_000, step: 10) {
                LabeledContent("单次上传上限", value: "\(viewModel.visionBackend.maximumUploadMegabytes) MB")
            }

            if !viewModel.visionBackend.missingLASConfigurationRoles.isEmpty {
                Label(
                    "缺少配置角色：\(viewModel.visionBackend.missingLASConfigurationRoles.map(\.displayName).joined(separator: ", "))",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Button {
                isShowingLASProbeImporter = true
            } label: {
                if viewModel.isProbingLAS {
                    ProgressView()
                } else {
                    Label("用非私密小视频做真实探测", systemImage: "waveform.path.ecg")
                }
            }
            .disabled(viewModel.isProbingLAS || !viewModel.visionBackend.missingLASConfigurationRoles.isEmpty)

            ForEach(viewModel.cloudCapabilities.filter { !$0.role.hasPrefix("ark") }) { capability in
                VStack(alignment: .leading, spacing: 3) {
                    LabeledContent(capability.role, value: "\(capability.status) · \(capability.probeLevel)")
                    Text("探测：\(capability.lastProbedAt.formatted()) · 到期：\(capability.expiresAt.formatted())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.visionBackend.requiresRunScopedConsent {
                Button(viewModel.isNextCloudRunAuthorized ? "下一次 LAS 分析已授权" : "授权下一次 LAS 分析（可能收费）") {
                    Task { await viewModel.authorizeNextCloudAnalysisRun() }
                }
                .disabled(viewModel.isNextCloudRunAuthorized || missingFreshLASRoles.isEmpty == false)
                Text("一次性同意只对随后实际 AssetProbe 生成的 run + fingerprint + planHash 生效；配置变化或 App 重启后失效。费用未知且可能收费。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("原视频会以流式 multipart 方式暂存到你管理的 TOS，供四个 LAS 算子复用；完成、取消或失败后立即尝试删除，失败会保留 cleanup-pending，最长 24 小时重试。结果可保留。公开发布仍因缺少真实 presigned broker 而阻断。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One glance answers "现在到底在用什么": per-role (语言/视觉/检索) effective backend,
    /// mode-aware — the pipeline's actual resolution, not the aspirational setting.
    @ViewBuilder
    private var activeRolesSection: some View {
        if let roles = viewModel.activeRoles {
            Section("当前生效") {
                LabeledContent("请求模式", value: viewModel.visionBackend.requestedMode.displayName)
                if !missingFreshLASRoles.isEmpty,
                   viewModel.visionBackend.requiresRunScopedConsent {
                    LabeledContent("下一次有效模式", value: "等待真实探测")
                    Text("缺少或过期角色：\(missingFreshLASRoles.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent {
                    Text(roles.text).multilineTextAlignment(.trailing)
                } label: {
                    Label("语言", systemImage: "text.bubble")
                }
                LabeledContent {
                    Text(roles.vision).multilineTextAlignment(.trailing)
                } label: {
                    Label("视觉", systemImage: "eye")
                }
                LabeledContent {
                    Text(roles.retrieval).multilineTextAlignment(.trailing)
                } label: {
                    Label("检索", systemImage: "magnifyingglass")
                }
            }
        }
    }

    private var deviceSection: some View {
        Section("设备") {
            LabeledContent("设备内存", value: viewModel.memorySummary)
            if let recommendedModel = viewModel.recommendedModel {
                LabeledContent("推荐模型", value: recommendedModel.displayName)
            }
            if !viewModel.canRunVisionLocally {
                visionUnavailableHint
            }
            if viewModel.isRefreshing && viewModel.models.isEmpty {
                ProgressView()
            }
        }
    }

    /// One section per model role. 使用 (set active) only exists for 语言 — the vision/embedding
    /// models are loaded by the pipeline for their role, never as the chat/scripting model.
    @ViewBuilder
    private func modelGroup(_ purpose: ModelPurpose) -> some View {
        let models = viewModel.runnableModels(for: purpose)
        if !models.isEmpty {
            Section {
                ForEach(models) { model in
                    ModelManagementRow(
                        model: model,
                        isActive: purpose == .language && model.id == viewModel.selectedModelID,
                        isOperating: model.id == viewModel.operationModelID,
                        downloadProgress: model.id == viewModel.operationModelID ? viewModel.downloadProgress : nil,
                        showsUse: purpose == .language,
                        select: { viewModel.selectModel(model.model) },
                        downloadModel: {
                            viewModel.beginDownload(model)
                        },
                        importModel: {
                            importTarget = model
                            isShowingModelImporter = true
                        },
                        cancelOperation: { viewModel.cancelOperation() },
                        delete: { Task { await viewModel.delete(model) } }
                    )
                }
            } header: {
                Text("\(purpose.displayName)模型 · \(purpose.usage)")
            }
        }
    }

    /// Where the disk went: imported videos, downloaded model weights, and the retrieval index.
    @ViewBuilder
    private var storageSection: some View {
        if let storage = viewModel.storage {
            Section {
                LabeledContent("视频文件", value: SettingsViewModel.formatBytes(storage.videoBytes))
                LabeledContent("模型文件", value: SettingsViewModel.formatBytes(storage.modelBytes))
                LabeledContent("检索索引", value: SettingsViewModel.formatBytes(storage.indexBytes))
                LabeledContent("合计", value: SettingsViewModel.formatBytes(storage.totalBytes))
            } header: {
                Text("存储")
            } footer: {
                Text("视频随对应拆解删除；模型可在上方删除，需要时重新下载。")
            }
        }
    }

    /// Shown when no vision model fits this device: on-device AI is text-only, so 画面理解 (拆解) must
    /// use the cloud. Offers a one-tap switch to 云端 mode.
    private var visionUnavailableHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("本机内存只够跑语言模型，做不了视频画面理解（拆解需要视觉模型）。建议用云端 AI。")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("切换到云端 AI") {
                viewModel.selectVisionBackend(.cloud)
            }
            .font(.callout.weight(.semibold))
        }
        .padding(.vertical, 4)
    }

    private var generationSection: some View {
        Section("生成参数") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(
                    "发散度",
                    value: String(format: "%.2f", viewModel.generationConfig.temperature)
                )
                Slider(value: temperatureBinding, in: GenerationConfigBounds.temperature)
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Top P", value: String(format: "%.2f", viewModel.generationConfig.topP))
                Slider(value: topPBinding, in: GenerationConfigBounds.topP)
            }

            Stepper(value: maxTokensBinding, in: GenerationConfigBounds.maxTokens, step: 64) {
                LabeledContent("回答长度", value: "\(viewModel.generationConfig.maxTokens)")
            }
        }
    }

    private var requestedModeBinding: Binding<CloudAnalysisRequestedMode> {
        Binding(
            get: { viewModel.visionBackend.requestedMode },
            set: { mode in
                var settings = viewModel.visionBackend
                settings.requestedMode = mode
                viewModel.updateVisionBackend(settings)
            }
        )
    }

    private var lasEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.visionBackend.las.isEnabled },
            set: { enabled in
                var settings = viewModel.visionBackend
                settings.las.isEnabled = enabled
                viewModel.updateVisionBackend(settings)
            }
        )
    }

    private var tosBucketBinding: Binding<String> {
        Binding(
            get: { viewModel.visionBackend.staging.bucket },
            set: { value in
                var settings = viewModel.visionBackend
                settings.staging.bucket = value
                viewModel.updateVisionBackend(settings)
            }
        )
    }

    private var tosPrefixBinding: Binding<String> {
        Binding(
            get: { viewModel.visionBackend.staging.objectPrefix },
            set: { value in
                var settings = viewModel.visionBackend
                settings.staging.objectPrefix = value
                viewModel.updateVisionBackend(settings)
            }
        )
    }

    private var tosReferenceBinding: Binding<String> {
        Binding(
            get: { viewModel.visionBackend.staging.credentialReferenceID },
            set: { value in
                var settings = viewModel.visionBackend
                settings.staging.credentialReferenceID = value
                viewModel.updateVisionBackend(settings)
            }
        )
    }

    private var tosExpiryBinding: Binding<Date> {
        Binding(
            get: {
                viewModel.visionBackend.staging.temporaryCredentialExpiresAt
                    ?? Date().addingTimeInterval(3_600)
            },
            set: { value in
                var settings = viewModel.visionBackend
                settings.staging.temporaryCredentialExpiresAt = value
                viewModel.updateVisionBackend(settings)
            }
        )
    }

    private var missingFreshLASRoles: [String] {
        let required = [
            "lasVideoStoryboard",
            "lasVideoFineUnderstanding",
            "lasScriptGeneration",
            "lasEnhancedASR",
            "mediaStaging",
        ]
        let fresh = Set(viewModel.cloudCapabilities.compactMap { capability in
            capability.status == "available"
                && capability.probeLevel == "liveMedia"
                && capability.expiresAt > Date()
                ? capability.role : nil
        })
        return required.filter { !fresh.contains($0) }
    }

    private var cloudBaseURLBinding: Binding<String> {
        Binding(
            get: { viewModel.visionBackend.cloudBaseURL },
            set: { viewModel.setCloudBaseURL($0) }
        )
    }

    private var cloudModelBinding: Binding<String> {
        Binding(
            get: { viewModel.visionBackend.cloudModel },
            set: { viewModel.setCloudModel($0) }
        )
    }

    private var cloudTextModelBinding: Binding<String> {
        Binding(
            get: { viewModel.visionBackend.cloudTextModel },
            set: { viewModel.setCloudTextModel($0) }
        )
    }

    private var uploadLimitBinding: Binding<Int> {
        Binding(
            get: { viewModel.visionBackend.maximumUploadMegabytes },
            set: { megabytes in
                var settings = viewModel.visionBackend
                settings.maximumUploadMegabytes = megabytes
                viewModel.updateVisionBackend(settings)
            }
        )
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { viewModel.generationConfig.temperature },
            set: { viewModel.setTemperature($0) }
        )
    }

    private var topPBinding: Binding<Double> {
        Binding(
            get: { viewModel.generationConfig.topP },
            set: { viewModel.setTopP($0) }
        )
    }

    private var maxTokensBinding: Binding<Int> {
        Binding(
            get: { viewModel.generationConfig.maxTokens },
            set: { viewModel.setMaxTokens($0) }
        )
    }
}

private struct ModelManagementRow: View {
    let model: ManagedModel
    let isActive: Bool
    let isOperating: Bool
    let downloadProgress: ModelDownloadProgress?
    var showsUse: Bool = true
    let select: () -> Void
    let downloadModel: () -> Void
    let importModel: () -> Void
    let cancelOperation: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(statusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("使用中")
                }
            }

            if isOperating {
                if let fractionCompleted = downloadProgress?.fractionCompleted {
                    ProgressView(value: fractionCompleted)
                } else {
                    ProgressView()
                }
                Text(SettingsViewModel.formatProgress(downloadProgress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if showsUse {
                    Button("使用", action: select)
                        .disabled(isActive)
                }

                if isOperating {
                    Button("取消", role: .cancel, action: cancelOperation)
                } else if model.isDownloaded {
                    Button("删除", role: .destructive, action: delete)
                } else {
                    Button(action: downloadModel) {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                    .disabled(!model.canRunOnDevice)

                    Button(action: importModel) {
                        Label("导入", systemImage: "folder.badge.plus")
                    }
                    .disabled(!model.canRunOnDevice)
                }

                Spacer(minLength: 0)
            }
            // Bordered pills keep each action's icon + label grouped as one unit, so the icon clearly
            // belongs to its button (borderless let the download glyph read as part of 使用).
            .buttonStyle(.bordered)
            .controlSize(.small)
            .labelStyle(CompactLabelStyle())
        }
        .padding(.vertical, 4)
    }

    // The purpose lives in the group header; only runnable models reach this row, so no
    // "内存不足" state is shown here — the sections filter those out.
    private var statusSummary: String {
        var parts: [String] = []

        if model.isRecommended {
            parts.append("推荐")
        }

        if model.isDownloaded {
            parts.append(SettingsViewModel.formatBytes(model.storageBytes))
        } else {
            // estimatedMemoryBytes ≈ 4-bit weight file size; good enough to set expectations.
            parts.append("未下载 · 约 \(SettingsViewModel.formatBytes(model.model.estimatedMemoryBytes))")
        }

        return parts.joined(separator: " · ")
    }
}

/// Tightens the gap between a button's icon and title — the default Label spacing read too loose
/// inside the small bordered pills.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
