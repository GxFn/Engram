import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var importTarget: ManagedModel?
    @State private var isShowingModelImporter = false

    public init(viewModel: SettingsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            deviceSection
            engineSection
            modelSection
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
                    select: { viewModel.selectModel(model.model) },
                    importModel: {
                        importTarget = model
                        isShowingModelImporter = true
                    },
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
    let select: () -> Void
    let importModel: () -> Void
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
                ProgressView()
            }

            HStack {
                Button("Use", action: select)
                    .disabled(isActive)

                if model.isDownloaded {
                    Button("Delete", role: .destructive, action: delete)
                } else {
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
