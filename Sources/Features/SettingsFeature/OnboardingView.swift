import SwiftUI
import UniformTypeIdentifiers

public struct OnboardingView: View {
    @State private var viewModel: SettingsViewModel
    @State private var importTarget: ManagedModel?
    @State private var downloadTarget: ManagedModel?
    @State private var isShowingModelImporter = false
    @State private var isShowingDownloadConfirmation = false
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
                            downloadProgress: recommendedModel.id == viewModel.operationModelID
                                ? viewModel.downloadProgress
                                : nil,
                            downloadModel: {
                                downloadTarget = recommendedModel
                                isShowingDownloadConfirmation = true
                            },
                            importModel: {
                                importTarget = recommendedModel
                                isShowingModelImporter = true
                            },
                            cancelOperation: { viewModel.cancelOperation() }
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
            .confirmationDialog(
                "Download Model",
                isPresented: $isShowingDownloadConfirmation,
                titleVisibility: .visible,
                presenting: downloadTarget
            ) { model in
                Button("Download") {
                    viewModel.beginDownload(model)
                }
            } message: { _ in
                Text("Large public model download. Use Wi-Fi or a stable connection.")
            }
            .navigationTitle("Welcome")
        }
    }
}

private struct ModelSetupRow: View {
    let model: ManagedModel
    let isOperating: Bool
    let downloadProgress: ModelDownloadProgress?
    let downloadModel: () -> Void
    let importModel: () -> Void
    let cancelOperation: () -> Void

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
                if let fractionCompleted = downloadProgress?.fractionCompleted {
                    ProgressView(value: fractionCompleted)
                } else {
                    ProgressView()
                }
            }

            if !model.isDownloaded {
                if isOperating {
                    Button("Cancel", role: .cancel, action: cancelOperation)
                } else {
                    Button(action: downloadModel) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .disabled(!model.canRunOnDevice)

                    Button(action: importModel) {
                        Label("Import Model Folder", systemImage: "folder.badge.plus")
                    }
                    .disabled(!model.canRunOnDevice)
                }
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
