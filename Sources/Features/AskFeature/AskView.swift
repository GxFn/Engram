import EngineKit
import RAGCore
import SwiftUI

/// Ask surface — "问出来". During M1 this doubles as the engine debugging
/// console: streaming tokens, engine badge, per-message metrics on long press.
/// Citations attach in M2 once retrieval exists.
public struct AskView: View {
    @State private var viewModel: AskViewModel
    @State private var draft = ""
    @State private var isShowingControls = false
    @FocusState private var composerFocused: Bool
    private let onCitationSelected: @MainActor (CitationRef) -> Void

    public init(
        engine: any LLMEngine,
        model: ModelIdentity,
        generationConfig: GenerationConfig = .default,
        retriever: (any Retriever)? = nil,
        onCitationSelected: @escaping @MainActor (CitationRef) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: AskViewModel(
            engine: engine,
            model: model,
            generationConfig: generationConfig,
            retriever: retriever
        ))
        self.onCitationSelected = onCitationSelected
    }

    public init(
        viewModel: AskViewModel,
        onCitationSelected: @escaping @MainActor (CitationRef) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onCitationSelected = onCitationSelected
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            composer
        }
        .navigationTitle("")
        // Pin the nav bar to its compact height so there's no collapsing large title. The visible
        // 问答 title lives in the fixed header below, so it never rides up with the message scroll.
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $isShowingControls) { controlsSheet }
    }

    private var header: some View {
        // A fixed large title + engine bar, both outside the message ScrollView so neither scrolls
        // with the chat. Matches 洞察's big-title layout; the title can't collapse because it's plain
        // content, not a collapsing navigation large title.
        VStack(alignment: .leading, spacing: 10) {
            Text("问答")
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            engineBar
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var engineBar: some View {
        HStack(spacing: 10) {
            Label(viewModel.engineName, systemImage: "cpu")
                .font(.subheadline.weight(.semibold))

            Text(viewModel.modelName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if viewModel.isRetrieving {
                Label("检索中", systemImage: "sparkle.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else if viewModel.isGenerating {
                Label("生成中", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .symbolEffect(.variableColor, isActive: true)
            }

            Button {
                isShowingControls = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline)
                    .foregroundStyle(controlsActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("问答设置")
        }
    }

    /// Non-default style/scope highlights the controls button so an active filter is visible.
    private var controlsActive: Bool {
        viewModel.answerStyle != .standard || viewModel.scope != .all
    }

    private var controlsSheet: some View {
        NavigationStack {
            Form {
                Section("回答风格") {
                    Picker("风格", selection: styleBinding) {
                        ForEach(AskViewModel.AnswerStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("问答范围") {
                    Picker("范围", selection: scopeBinding) {
                        ForEach(AskViewModel.AskScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("默认基于你保存的全部内容；可限定只问剪藏或只问拆解。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("生成参数") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("发散度", value: String(format: "%.2f", viewModel.generationConfig.temperature))
                        Slider(value: temperatureBinding, in: AskViewModel.temperatureRange)
                    }
                    Stepper(value: maxTokensBinding, in: AskViewModel.maxTokensRange, step: 128) {
                        LabeledContent("回答长度", value: "\(viewModel.generationConfig.maxTokens)")
                    }
                }
            }
            .navigationTitle("问答设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isShowingControls = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var styleBinding: Binding<AskViewModel.AnswerStyle> {
        Binding(get: { viewModel.answerStyle }, set: { viewModel.answerStyle = $0 })
    }

    private var scopeBinding: Binding<AskViewModel.AskScope> {
        Binding(get: { viewModel.scope }, set: { viewModel.scope = $0 })
    }

    private var temperatureBinding: Binding<Double> {
        Binding(get: { viewModel.generationConfig.temperature }, set: { viewModel.setTemperature($0) })
    }

    private var maxTokensBinding: Binding<Int> {
        Binding(get: { viewModel.generationConfig.maxTokens }, set: { viewModel.setMaxTokens($0) })
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    }

                    ForEach(viewModel.messages) { message in
                        AskMessageRow(
                            message: message,
                            onCitationSelected: onCitationSelected
                        )
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
        HStack(alignment: .bottom, spacing: 8) {
            TextField("问问你的剪藏与拆解", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .disabled(viewModel.isGenerating)
                .onSubmit(sendDraft)
                .padding(.leading, 16)
                .padding(.vertical, 10)

            if viewModel.isGenerating {
                Button(action: viewModel.stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .padding(.bottom, 4)
                .accessibilityLabel("停止")
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.trailing, 6)
                .padding(.bottom, 4)
                .accessibilityLabel("发送")
            }
        }
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 38))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("问问你的剪藏与拆解")
                    .font(.title3.weight(.semibold))
                Text("基于你保存的全部内容回答，并附上可点击的来源引用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                ForEach(AskViewModel.suggestedPrompts, id: \.self) { prompt in
                    Button {
                        submit(prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "text.magnifyingglass")
                                .foregroundStyle(.secondary)
                            Text(prompt)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isGenerating)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 240)
        .padding(.horizontal, 20)
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
        submit(submittedText)
    }

    /// Sends any text (draft or a tapped suggestion) if idle.
    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !viewModel.isGenerating else {
            return
        }
        composerFocused = false
        viewModel.send(trimmed)
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
    let onCitationSelected: @MainActor (CitationRef) -> Void

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

                if !message.citations.isEmpty {
                    citations
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

    private var citations: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(message.citations.enumerated()), id: \.element.chunkID) { index, citation in
                Button {
                    onCitationSelected(citation)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text("[\(index + 1)]")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        Text(citation.snippet)
                            .font(.caption)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open citation \(index + 1)")
            }
        }
        .padding(.top, 4)
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
