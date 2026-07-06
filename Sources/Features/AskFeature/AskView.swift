import EngineKit
import SwiftUI

/// Ask surface — "问出来". During M1 this doubles as the engine debugging
/// console: streaming tokens, engine badge, per-message metrics on long press.
/// Citations attach in M2 once retrieval exists.
public struct AskView: View {
    @State private var viewModel: AskViewModel
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    public init(
        engine: any LLMEngine,
        model: ModelIdentity,
        generationConfig: GenerationConfig = .default
    ) {
        _viewModel = State(initialValue: AskViewModel(
            engine: engine,
            model: model,
            generationConfig: generationConfig
        ))
    }

    public init(viewModel: AskViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            composer
        }
        .navigationTitle("Ask")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(viewModel.engineName, systemImage: "cpu")
                .font(.subheadline.weight(.semibold))

            Text(viewModel.modelName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if viewModel.isGenerating {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.messages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "questionmark.bubble")
                                .font(.system(size: 34))
                                .foregroundStyle(.secondary)
                            Text("Ask Engram")
                                .font(.title3.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    }

                    ForEach(viewModel.messages) { message in
                        AskMessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: viewModel.messages.last?.text) { _, _ in
                scrollToLatest(proxy)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Engram", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($composerFocused)
                .disabled(viewModel.isGenerating)
                .onSubmit(sendDraft)

            Button(action: sendDraft) {
                Image(systemName: "paperplane.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
            .accessibilityLabel("Send")

            Button(action: viewModel.stop) {
                Image(systemName: "stop.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.isGenerating)
            .accessibilityLabel("Stop")
        }
        .padding()
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isGenerating
    }

    private func sendDraft() {
        guard canSend else {
            return
        }

        let submittedText = draft
        draft = ""
        viewModel.send(submittedText)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let id = viewModel.messages.last?.id else {
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

private struct AskMessageRow: View {
    let message: AskViewModel.DisplayMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(message.text.isEmpty ? "..." : message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .foregroundStyle(message.errorMessage == nil ? Color.primary : Color.red)

                if let metricsSummary {
                    Text(metricsSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 8))

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
    }

    private var backgroundStyle: Color {
        switch message.role {
        case .user:
            Color.accentColor.opacity(0.18)
        case .assistant:
            Color.secondary.opacity(0.12)
        }
    }

    private var metricsSummary: String? {
        guard message.role == .assistant, let metrics = message.metrics else {
            return nil
        }

        var parts = ["\(metrics.outputTokenCount) tokens"]
        if let firstTokenLatencyMillis = metrics.firstTokenLatencyMillis {
            parts.append(String(format: "TTFT %.0f ms", firstTokenLatencyMillis))
        }
        if let tokensPerSecond = metrics.tokensPerSecond {
            parts.append(String(format: "%.1f tok/s", tokensPerSecond))
        }

        return parts.joined(separator: " · ")
    }
}
