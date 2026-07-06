import SwiftUI

public struct OnboardingView: View {
    @State private var viewModel: SettingsViewModel
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
                            download: { Task { await viewModel.download(recommendedModel) } }
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
            .navigationTitle("Welcome")
        }
    }
}

private struct ModelSetupRow: View {
    let model: ManagedModel
    let isOperating: Bool
    let download: () -> Void

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
                Button(action: download) {
                    Label("Download", systemImage: "arrow.down.circle")
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
