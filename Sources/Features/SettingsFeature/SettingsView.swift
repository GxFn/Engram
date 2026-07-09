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
                deviceSection
                engineSection
                modelSection
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
        .navigationTitle("Settings")
    }

    private var deviceSection: some View {
        Section("Device") {
            LabeledContent("Memory", value: viewModel.memorySummary)
            if let recommendedModel = viewModel.recommendedModel {
                LabeledContent("Recommended", value: recommendedModel.displayName)
            }
        }
    }

    private var engineSection: some View {
        Section("Engine") {
            Picker("Active Engine", selection: engineBinding) {
                ForEach(viewModel.engines) { engine in
                    Text(engine.displayName).tag(engine.id)
                }
            }
        }
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
            TextField("Base URL（如 https://ark.cn-beijing.volces.com/api/v3）", text: cloudBaseURLBinding)
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("文本模型（如 doubao-1.5-pro）", text: cloudTextModelBinding)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("视觉模型（如 doubao-vision-pro）", text: cloudModelBinding)
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
            Text("需自备账号与 API Key。兼容豆包/DeepSeek/通义千问/GLM 等 OpenAI 兼容接口；文本用于剧本化与问答，视觉用于画面理解。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelSection: some View {
        Section("Models") {
            if viewModel.isRefreshing && viewModel.models.isEmpty {
                ProgressView()
            }

            ForEach(viewModel.models) { model in
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
        }
    }

    private var generationSection: some View {
        Section("Generation") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(
                    "Temperature",
                    value: String(format: "%.2f", viewModel.generationConfig.temperature)
                )
                Slider(value: temperatureBinding, in: GenerationConfigBounds.temperature)
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Top P", value: String(format: "%.2f", viewModel.generationConfig.topP))
                Slider(value: topPBinding, in: GenerationConfigBounds.topP)
            }

            Stepper(value: maxTokensBinding, in: GenerationConfigBounds.maxTokens, step: 64) {
                LabeledContent("Max Tokens", value: "\(viewModel.generationConfig.maxTokens)")
            }
        }
    }

    private var engineBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedEngineID },
            set: { viewModel.selectEngine(id: $0) }
        )
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
                        .accessibilityLabel("Active")
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

            HStack {
                Button("Use", action: select)
                    .disabled(isActive)

                if isOperating {
                    Button("Cancel", role: .cancel, action: cancelOperation)
                } else if model.isDownloaded {
                    Button("Delete", role: .destructive, action: delete)
                } else {
                    Button(action: downloadModel) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .disabled(!model.canRunOnDevice)

                    Button(action: importModel) {
                        Label("Import", systemImage: "folder.badge.plus")
                    }
                    .disabled(!model.canRunOnDevice)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var statusSummary: String {
        var parts: [String] = []

        if model.isRecommended {
            parts.append("recommended")
        }

        if model.isDownloaded {
            parts.append(SettingsViewModel.formatBytes(model.storageBytes))
        } else {
            parts.append("not downloaded")
        }

        if !model.canRunOnDevice {
            parts.append("memory limited")
        }

        return parts.joined(separator: " · ")
    }
}
