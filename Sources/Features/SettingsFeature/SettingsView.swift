import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var importTarget: ManagedModel?
    @State private var isShowingModelImporter = false
    @State private var cloudKeyInput = ""

    public init(viewModel: SettingsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            modeSection

            if viewModel.visionBackend.kind == .cloud {
                cloudSection
            } else {
                localModelSection
            }

            generationSection

            if let errorMessage = viewModel.errorMessage {
                Section {
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
        .navigationTitle("设置")
    }

    private var modeSection: some View {
        Section {
            Picker("AI 模式", selection: visionKindBinding) {
                ForEach(VisionBackendKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Text(viewModel.visionBackend.kind == .cloud
                ? "云端：文本与画面都走你配置的云端 AI，无需下载模型；帧与文本会上传到你的服务。"
                : "本地：全部在本机运行，完全离线、免费；需下载模型，部分机型可能跑不动。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("AI 模式")
        }
    }

    private var cloudSection: some View {
        Section("云端 AI 服务") {
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
                Label("云端配置不完整（需 Base URL、文本/视觉模型 ID 和 API Key）；补全前将全部使用本地模型。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("兼容豆包 / DeepSeek / 通义 / GLM 等 OpenAI 接口；模型请填接入点 ID（豆包形如 ep-…）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var localModelSection: some View {
        Section {
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

            ForEach(viewModel.runnableModels) { model in
                ModelManagementRow(
                    model: model,
                    isActive: model.id == viewModel.selectedModelID,
                    isOperating: model.id == viewModel.operationModelID,
                    downloadProgress: model.id == viewModel.operationModelID ? viewModel.downloadProgress : nil,
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
            Text("本地模型")
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

    private var visionKindBinding: Binding<VisionBackendKind> {
        Binding(
            get: { viewModel.visionBackend.kind },
            set: { viewModel.selectVisionBackend($0) }
        )
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
    let select: () -> Void
    let downloadModel: () -> Void
    let importModel: () -> Void
    let cancelOperation: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        purposeTag
                    }

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
                Button("使用", action: select)
                    .disabled(isActive)

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

    private var purposeTag: some View {
        Text(model.purpose.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    // Leads with the model's usage (its 用途); only runnable models reach this row, so no
    // "内存不足" state is shown here — the section filters those out.
    private var statusSummary: String {
        var parts: [String] = [model.purpose.usage]

        if model.isRecommended {
            parts.append("推荐")
        }

        parts.append(model.isDownloaded ? SettingsViewModel.formatBytes(model.storageBytes) : "未下载")

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
