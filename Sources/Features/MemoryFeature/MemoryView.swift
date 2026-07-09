import ClipCore
import Foundation
import Observation
import ScriptCore
import SwiftUI

#if os(iOS)
import PhotosUI
import UniformTypeIdentifiers
import UIKit
#endif

public struct MemoryClip: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let sourceURL: URL?
    public let note: String?
    public let bodyText: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let state: ClipState
    public let failureReason: String?
    public let failureRetryable: Bool
    public let indexPreview: String?
    /// Persisted ContentBreakdown (Script) JSON; nil for text/url clips or when not yet indexed.
    public let scriptJSON: String?
    /// Coarse content type, used to route the clip into the 剪藏 vs 拆解 library.
    public let sourceKind: ClipSourceKind

    public init(
        id: String,
        title: String,
        sourceURL: URL?,
        note: String?,
        bodyText: String?,
        createdAt: Date,
        updatedAt: Date,
        state: ClipState,
        failureReason: String?,
        failureRetryable: Bool,
        indexPreview: String?,
        scriptJSON: String? = nil,
        sourceKind: ClipSourceKind = .text
    ) {
        self.id = id
        self.title = title
        self.sourceURL = sourceURL
        self.note = note
        self.bodyText = bodyText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.failureReason = failureReason
        self.failureRetryable = failureRetryable
        self.indexPreview = indexPreview
        self.scriptJSON = scriptJSON
        self.sourceKind = sourceKind
    }

    /// Whether this item belongs to the 拆解 (video) library rather than 剪藏 (text/url).
    public var isVideoBreakdown: Bool {
        sourceKind == .video
    }

    /// Decoded breakdown, if this clip carries a persisted script.
    public var breakdown: Script? {
        ScriptCoding.decode(json: scriptJSON)
    }

    /// Copy/share text handed off to external generators (豆包 / 即梦). Prefers the
    /// structured breakdown rendering, falling back to the plain indexed body text.
    public var handoffText: String {
        if let breakdown {
            return ScriptRendering.indexableText(breakdown)
        }
        return bodyText ?? ""
    }
}

public struct MemoryNavigationTarget: Identifiable, Hashable, Sendable {
    public var id: String { "\(clipID)#\(chunkID)" }
    public let clipID: String
    public let chunkID: String

    public init(clipID: String, chunkID: String) {
        self.clipID = clipID
        self.chunkID = chunkID
    }
}

public struct MemoryClient: Sendable {
    public let loadItems: @Sendable () async throws -> [MemoryClip]
    public let digestPending: @Sendable () async throws -> Void
    public let retryClip: @Sendable (String) async throws -> Void
    public let importVideo: @Sendable (URL) async throws -> Void
    public let addClip: @Sendable (MemoryCaptureInput) async throws -> Void
    public let deleteClip: @Sendable (String) async throws -> Void
    public let editClip: @Sendable (String, String) async throws -> Void

    public init(
        loadItems: @escaping @Sendable () async throws -> [MemoryClip],
        digestPending: @escaping @Sendable () async throws -> Void,
        retryClip: @escaping @Sendable (String) async throws -> Void,
        importVideo: @escaping @Sendable (URL) async throws -> Void = { _ in },
        addClip: @escaping @Sendable (MemoryCaptureInput) async throws -> Void = { _ in },
        deleteClip: @escaping @Sendable (String) async throws -> Void = { _ in },
        editClip: @escaping @Sendable (String, String) async throws -> Void = { _, _ in }
    ) {
        self.loadItems = loadItems
        self.digestPending = digestPending
        self.retryClip = retryClip
        self.importVideo = importVideo
        self.addClip = addClip
        self.deleteClip = deleteClip
        self.editClip = editClip
    }

    public static let empty = MemoryClient(
        loadItems: { [] },
        digestPending: {},
        retryClip: { _ in },
        importVideo: { _ in },
        addClip: { _ in },
        deleteClip: { _ in },
        editClip: { _, _ in }
    )
}

/// In-app 剪藏 capture input (text snippet or a URL to fetch).
public enum MemoryCaptureInput: Sendable, Equatable {
    case text(String)
    case url(URL)
}

public enum MemoryVideoImportSelection: Sendable, Equatable {
    case cancelled
    case file(URL)
}

/// The two first-class libraries backed by the same store: 剪藏 (text/url knowledge) and
/// 拆解 (video breakdowns). Each tab renders the shared MemoryViewModel filtered by kind.
public enum MemoryLibraryKind: Sendable, Hashable {
    case clips
    case studio

    public var title: String {
        switch self {
        case .clips: "剪藏"
        case .studio: "拆解"
        }
    }

    var sourceKinds: Set<ClipSourceKind> {
        switch self {
        case .clips: [.text, .url]
        case .studio: [.video]
        }
    }
}

@MainActor
@Observable
public final class MemoryViewModel {
    public private(set) var items: [MemoryClip] = []
    public private(set) var isRefreshing = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let client: MemoryClient

    public init(client: MemoryClient = .empty) {
        self.client = client
    }

    /// Items for one library tab (剪藏 vs 拆解), filtered from the shared store.
    public func items(for kind: MemoryLibraryKind) -> [MemoryClip] {
        items.filter { kind.sourceKinds.contains($0.sourceKind) }
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            items = try await client.loadItems()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func digestAndRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await client.digestPending()
            items = try await client.loadItems()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func retry(_ item: MemoryClip) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await client.retryClip(item.id)
            try await client.digestPending()
            items = try await client.loadItems()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func importVideo(_ selection: MemoryVideoImportSelection) async {
        guard case let .file(url) = selection else {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await client.importVideo(url)
            items = try await client.loadItems()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func addClip(_ input: MemoryCaptureInput) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await client.addClip(input)
            try await client.digestPending()
            items = try await client.loadItems()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func delete(_ item: MemoryClip) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Optimistic removal so the row disappears immediately.
        items.removeAll { $0.id == item.id }
        do {
            try await client.deleteClip(item.id)
            items = try await client.loadItems()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
            items = (try? await client.loadItems()) ?? items
        }
    }

    /// Saves user-corrected content for a clip and re-indexes it, so 问答 uses the fixed text.
    public func editContent(_ item: MemoryClip, newText: String) async {
        guard !isRefreshing else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await client.editClip(item.id, trimmed)
            items = try await client.loadItems()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func reportImportFailure(_ error: Error) {
        errorMessage = String(describing: error)
    }
}

/// Memory surface — the app-side digest status timeline.
public struct MemoryView: View {
    @State private var viewModel: MemoryViewModel
    @Binding private var navigationTarget: MemoryNavigationTarget?
    @State private var isShowingVideoPicker = false
    @State private var isShowingClipCapture = false
    private let kind: MemoryLibraryKind

    public init(
        kind: MemoryLibraryKind = .clips,
        viewModel: MemoryViewModel = MemoryViewModel(),
        navigationTarget: Binding<MemoryNavigationTarget?> = .constant(nil)
    ) {
        self.kind = kind
        _viewModel = State(initialValue: viewModel)
        _navigationTarget = navigationTarget
    }

    private var items: [MemoryClip] {
        viewModel.items(for: kind)
    }

    public var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: kind == .studio ? "film.stack" : "tray.full",
                    description: Text(emptyDescription)
                )
            } else {
                List(items) { item in
                    NavigationLink {
                        MemoryDetailView(
                            item: item,
                            retry: { Task { await viewModel.retry(item) } },
                            onSaveEdit: { newText in Task { await viewModel.editContent(item, newText: newText) } }
                        )
                    } label: {
                        MemoryRow(item: item)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await viewModel.delete(item) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .refreshable {
                    await viewModel.digestAndRefresh()
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.red, in: Capsule())
                    .padding()
            }
        }
        .toolbar {
            if kind == .clips {
                ToolbarItem(placement: .automatic) {
                    Button {
                        isShowingClipCapture = true
                    } label: {
                        Label("剪藏", systemImage: "plus")
                    }
                    .accessibilityLabel("新建剪藏")
                    .disabled(viewModel.isRefreshing)
                }
            }
            #if os(iOS)
            if kind == .studio {
                ToolbarItem(placement: .automatic) {
                    Button {
                        isShowingVideoPicker = true
                    } label: {
                        Label("导入视频", systemImage: "video.badge.plus")
                    }
                    .accessibilityLabel("导入视频")
                    .disabled(viewModel.isRefreshing)
                }
            }
            #endif
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await viewModel.digestAndRefresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh clips")
                .disabled(viewModel.isRefreshing)
            }
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingVideoPicker) {
            VideoPickerView { result in
                isShowingVideoPicker = false
                switch result {
                case let .success(selection):
                    Task { await viewModel.importVideo(selection) }
                case let .failure(error):
                    viewModel.reportImportFailure(error)
                }
            }
        }
        #endif
        .sheet(isPresented: $isShowingClipCapture) {
            ClipCaptureSheet { input in
                isShowingClipCapture = false
                Task { await viewModel.addClip(input) }
            } cancel: {
                isShowingClipCapture = false
            }
        }
        .navigationTitle(kind.title)
        .navigationDestination(item: $navigationTarget) { target in
            if let item = viewModel.items.first(where: { $0.id == target.clipID }) {
                MemoryDetailView(
                    item: item,
                    highlightedChunkID: target.chunkID,
                    retry: { Task { await viewModel.retry(item) } },
                    onSaveEdit: { newText in Task { await viewModel.editContent(item, newText: newText) } }
                )
            } else {
                ContentUnavailableView("未找到内容", systemImage: "doc.text.magnifyingglass")
            }
        }
        .task {
            await viewModel.digestAndRefresh()
        }
        .onChange(of: navigationTarget) { _, target in
            guard target != nil else { return }
            Task { await viewModel.refresh() }
        }
    }

    private var emptyTitle: String {
        kind == .studio ? "还没有视频拆解" : "还没有剪藏"
    }

    private var emptyDescription: String {
        switch kind {
        case .studio:
            "点右上角导入本地视频，端侧/云端会拆出爆点结构与分镜剧本。"
        case .clips:
            "从任意 app 分享文本或链接到 Engram，之后就能问出来。"
        }
    }
}

#if os(iOS)
private enum VideoPickerError: Error, Equatable, Sendable {
    case providerFailed(String)
    case copyFailed(String)
}

private struct VideoPickerView: UIViewControllerRepresentable {
    let onCompletion: @MainActor @Sendable (Result<MemoryVideoImportSelection, VideoPickerError>) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        _ = uiViewController
        _ = context
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onCompletion: @MainActor @Sendable (Result<MemoryVideoImportSelection, VideoPickerError>) -> Void

        init(onCompletion: @escaping @MainActor @Sendable (Result<MemoryVideoImportSelection, VideoPickerError>) -> Void) {
            self.onCompletion = onCompletion
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            _ = picker
            guard let provider = results.first?.itemProvider else {
                onCompletion(.success(.cancelled))
                return
            }

            let typeIdentifier = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .movie) == true
            } ?? UTType.movie.identifier

            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [onCompletion] url, error in
                if let error {
                    Self.complete(.failure(.providerFailed(String(describing: error))), onCompletion: onCompletion)
                    return
                }

                guard let url else {
                    Self.complete(.success(.cancelled), onCompletion: onCompletion)
                    return
                }

                do {
                    let stableURL = try Self.copyPickerTemporaryFile(url)
                    Self.complete(.success(.file(stableURL)), onCompletion: onCompletion)
                } catch {
                    Self.complete(.failure(.copyFailed(String(describing: error))), onCompletion: onCompletion)
                }
            }
        }

        private static func complete(
            _ result: Result<MemoryVideoImportSelection, VideoPickerError>,
            onCompletion: @escaping @MainActor @Sendable (Result<MemoryVideoImportSelection, VideoPickerError>) -> Void
        ) {
            Task { @MainActor in
                onCompletion(result)
            }
        }

        private static func copyPickerTemporaryFile(_ url: URL) throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("EngramPickedVideos", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let pathExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let destination = directory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension(pathExtension)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        }
    }
}
#endif

private struct ClipCaptureSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case text = "文本"
        case url = "链接"
        var id: String { rawValue }
    }

    let submit: (MemoryCaptureInput) -> Void
    let cancel: () -> Void

    @State private var mode: Mode = .text
    @State private var text = ""
    @State private var urlString = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .text:
                    Section("文本") {
                        TextField("粘贴要剪藏的文本", text: $text, axis: .vertical)
                            .lineLimit(4...12)
                    }
                case .url:
                    Section("链接") {
                        TextField("https://…", text: $urlString)
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Text("剪藏时会联网抓取一次正文,之后问答离线。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("新建剪藏")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let input = makeInput() {
                            submit(input)
                        }
                    }
                    .disabled(makeInput() == nil)
                }
            }
        }
    }

    private func makeInput() -> MemoryCaptureInput? {
        switch mode {
        case .text:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        case .url:
            let trimmed = urlString.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }
            return .url(url)
        }
    }
}

private struct MemoryRow: View {
    let item: MemoryClip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 12)
                StateBadge(state: item.state)
            }
            if let sourceURL = item.sourceURL {
                Text(sourceURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let bodyText = item.bodyText, !bodyText.isEmpty {
                Text(bodyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MemoryDetailView: View {
    let item: MemoryClip
    var highlightedChunkID: String? = nil
    let retry: () -> Void
    var onSaveEdit: (String) -> Void = { _ in }

    @State private var isEditing = false
    @State private var editDraft = ""

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    StateBadge(state: item.state)
                }
                LabeledContent("Updated", value: item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                if let sourceURL = item.sourceURL {
                    LabeledContent("Source", value: sourceURL.absoluteString)
                }
                if let note = item.note, !note.isEmpty {
                    LabeledContent("Note", value: note)
                }
            }

            if let failureReason = item.failureReason {
                Section("Failure") {
                    Text(failureReason)
                    if item.failureRetryable {
                        Button("Retry") {
                            retry()
                        }
                    }
                }
            }

            if let breakdown = item.breakdown {
                if let hook = breakdown.hookStructure {
                    Section("爆点结构") {
                        HookStructureView(hook: hook)
                    }
                }

                if !breakdown.characters.isEmpty {
                    Section("人物") {
                        ForEach(Array(breakdown.characters.enumerated()), id: \.offset) { _, profile in
                            Text(profile)
                                .textSelection(.enabled)
                        }
                    }
                }

                if !breakdown.visualElements.isEmpty {
                    Section("视觉元素") {
                        Text(breakdown.visualElements.joined(separator: "、"))
                            .textSelection(.enabled)
                    }
                }

                if !breakdown.shots.isEmpty {
                    Section("分镜 (\(breakdown.shots.count))") {
                        ForEach(breakdown.shots.sorted { $0.index < $1.index }, id: \.index) { shot in
                            ShotRowView(shot: shot)
                        }
                    }
                }
            } else if let bodyText = item.bodyText, !bodyText.isEmpty {
                Section("Original") {
                    Text(bodyText)
                        .textSelection(.enabled)
                }
            }

            if let highlightedChunkID, !highlightedChunkID.isEmpty {
                Section("Citation") {
                    LabeledContent("Clip", value: item.id)
                    LabeledContent("Chunk", value: highlightedChunkID)
                }
            }
        }
        .navigationTitle(item.title)
        .toolbar {
            if canEditContent {
                ToolbarItem(placement: .automatic) {
                    Button {
                        editDraft = item.bodyText ?? ""
                        isEditing = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .accessibilityLabel("编辑内容")
                }
            }
            if !item.handoffText.isEmpty {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        ShareLink("分享剧本", item: item.handoffText)
                        #if os(iOS)
                        Button {
                            UIPasteboard.general.string = item.handoffText
                        } label: {
                            Label("复制全文", systemImage: "doc.on.doc")
                        }
                        #endif
                    } label: {
                        Label("投喂", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityLabel("复制或分享剧本，投喂到豆包/即梦")
                }
            }
        }
        .sheet(isPresented: $isEditing) { editSheet }
    }

    /// Text/URL clips carry their content as editable body text; video breakdowns are structured
    /// scripts (their 台词 is auto-corrected during analysis), so they aren't free-text editable here.
    private var canEditContent: Bool {
        item.breakdown == nil && !(item.bodyText ?? "").isEmpty
    }

    private var editSheet: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextEditor(text: $editDraft)
                        .frame(minHeight: 220)
                }
                Text("订正后会重新索引，问答会基于修正后的内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("编辑内容")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isEditing = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSaveEdit(editDraft)
                        isEditing = false
                    }
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct HookStructureView: View {
    let hook: HookAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledLine("钩子", hook.openingHook)
            if !hook.retentionDevices.isEmpty {
                labeledLine("留人", hook.retentionDevices.joined(separator: "、"))
            }
            if let payoff = hook.payoff, !payoff.isEmpty {
                labeledLine("爆点", payoff)
            }
            if let cta = hook.callToAction, !cta.isEmpty {
                labeledLine("CTA", cta)
            }
            if !hook.whyItWorks.isEmpty {
                labeledLine("为什么成立", hook.whyItWorks)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func labeledLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
    }
}

private struct ShotRowView: View {
    let shot: StoryboardShot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("分镜 \(shot.index + 1)  \(timeRange)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let narration = shot.narration, !narration.isEmpty {
                Text("台词: \(narration)").font(.subheadline)
            }
            if !shot.visualDescription.isEmpty {
                Text("画面: \(shot.visualDescription)").font(.subheadline)
            }
            if let pacing = shot.pacingNote, !pacing.isEmpty {
                Text("节奏: \(pacing)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 2)
    }

    private var timeRange: String {
        "\(format(shot.startSeconds))–\(format(shot.endSeconds))"
    }

    private func format(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? seconds : 0
        return String(format: "%.1fs", safe)
    }
}

private struct StateBadge: View {
    let state: ClipState

    var body: some View {
        Text(state.rawValue.capitalized)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch state {
        case .indexed:
            .green
        case .failed:
            .red
        case .fetching, .indexing, .transcribing, .analyzing, .scripting:
            .blue
        case .queued:
            .secondary
        }
    }

    private var background: Color {
        foreground.opacity(0.14)
    }
}
