import SwiftUI
import UniformTypeIdentifiers

public struct OnboardingView: View {
    @State private var viewModel: SettingsViewModel
    @State private var importTarget: ManagedModel?
    @State private var isShowingModelImporter = false
    private let complete: () -> Void

    public init(viewModel: SettingsViewModel, complete: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.complete = complete
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    LabeledContent("Memory", value: viewModel.memorySummary)
                    if let recommendedModel = viewModel.recommendedModel {
                        LabeledContent("Recommended", value: recommendedModel.displayName)
                    }
                }

                Section("Setup") {
                    if let recommendedModel = viewModel.recommendedModel {
                        ModelSetupRow(
                            model: recommendedModel,
                            isOperating: recommendedModel.id == viewModel.operationModelID,
                            importModel: {
                                importTarget = recommendedModel
                                isShowingModelImporter = true
                            }
                        )
                    } else if viewModel.isRefreshing {
                        ProgressView()
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: complete) {
                        Label("Continue", systemImage: "checkmark.circle.fill")
                    }
                }
            }
            .task { await viewModel.refresh() }
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
            .navigationTitle("Welcome")
        }
    }
}

private struct ModelSetupRow: View {
    let model: ManagedModel
    let isOperating: Bool
    let importModel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.displayName)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(statusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if isOperating {
                ProgressView()
            }

            if !model.isDownloaded {
                Button(action: importModel) {
                    Label("Import Model Folder", systemImage: "folder.badge.plus")
                }
                .disabled(!model.canRunOnDevice || isOperating)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusSummary: String {
        if model.isDownloaded {
            return "Ready · \(SettingsViewModel.formatBytes(model.storageBytes))"
        }

        if !model.canRunOnDevice {
            return "This device should use the smaller model."
        }

        return "Not downloaded"
    }
}
