import ClipCore
import Foundation
import Observation
import ScriptCore
import SwiftUI

#if os(iOS)
import AVFoundation
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
    /// Structured breakdown edit: applies the transform to the persisted script, re-indexes, and
    /// returns the updated script for immediate display.
    public let updateScript: @Sendable (String, @escaping @Sendable (Script) -> Script) async throws -> Script
    /// AI re-analysis: re-derives title/summary/爆点结构 from corrected 台词+字幕+背景; returns the
    /// updated script.
    public let reanalyzeScript: @Sendable (String) async throws -> Script

    public init(
        loadItems: @escaping @Sendable () async throws -> [MemoryClip],
        digestPending: @escaping @Sendable () async throws -> Void,
        retryClip: @escaping @Sendable (String) async throws -> Void,
        importVideo: @escaping @Sendable (URL) async throws -> Void = { _ in },
        addClip: @escaping @Sendable (MemoryCaptureInput) async throws -> Void = { _ in },
        deleteClip: @escaping @Sendable (String) async throws -> Void = { _ in },
        editClip: @escaping @Sendable (String, String) async throws -> Void = { _, _ in },
        updateScript: @escaping @Sendable (String, @escaping @Sendable (Script) -> Script) async throws -> Script = { _, _ in
            throw MemoryClientError.editingUnavailable
        },
        reanalyzeScript: @escaping @Sendable (String) async throws -> Script = { _ in
            throw MemoryClientError.editingUnavailable
        }
    ) {
        self.loadItems = loadItems
        self.digestPending = digestPending
        self.retryClip = retryClip
        self.importVideo = importVideo
        self.addClip = addClip
        self.deleteClip = deleteClip
        self.editClip = editClip
        self.updateScript = updateScript
        self.reanalyzeScript = reanalyzeScript
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

public enum MemoryClientError: Error, LocalizedError {
    case editingUnavailable

    public var errorDescription: String? { "剧本编辑暂不可用。" }
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

    /// Applies a structured breakdown edit (manual correction), refreshes the store, and returns
    /// the updated script for immediate in-place display. nil on failure (errorMessage set).
    public func updateScript(
        _ item: MemoryClip,
        transform: @escaping @Sendable (Script) -> Script
    ) async -> Script? {
        do {
            let updated = try await client.updateScript(item.id, transform)
            items = (try? await client.loadItems()) ?? items
            errorMessage = nil
            return updated
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// AI re-analysis of a breakdown's understanding fields from its corrected facts + 背景.
    public func reanalyzeScript(_ item: MemoryClip) async -> Script? {
        do {
            let updated = try await client.reanalyzeScript(item.id)
            items = (try? await client.loadItems()) ?? items
            errorMessage = nil
            return updated
        } catch {
            errorMessage = String(describing: error)
            return nil
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
    /// Invoked by a detail view's 问这条 action to open 问答 focused on that clip (wired by the shell).
    private let onAskAboutClip: (MemoryClip) -> Void

    public init(
        kind: MemoryLibraryKind = .clips,
        viewModel: MemoryViewModel = MemoryViewModel(),
        navigationTarget: Binding<MemoryNavigationTarget?> = .constant(nil),
        onAskAboutClip: @escaping (MemoryClip) -> Void = { _ in }
    ) {
        self.kind = kind
        _viewModel = State(initialValue: viewModel)
        _navigationTarget = navigationTarget
        self.onAskAboutClip = onAskAboutClip
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
                            onSaveEdit: { newText in Task { await viewModel.editContent(item, newText: newText) } },
                            onAskAboutClip: onAskAboutClip,
                            onUpdateScript: { transform in await viewModel.updateScript(item, transform: transform) },
                            onReanalyze: { await viewModel.reanalyzeScript(item) }
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
                    onSaveEdit: { newText in Task { await viewModel.editContent(item, newText: newText) } },
                    onAskAboutClip: onAskAboutClip,
                    onUpdateScript: { transform in await viewModel.updateScript(item, transform: transform) },
                    onReanalyze: { await viewModel.reanalyzeScript(item) }
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
    var onAskAboutClip: (MemoryClip) -> Void = { _ in }
    /// Structured breakdown edit; returns the updated script (nil on failure) for in-place display.
    var onUpdateScript: (@escaping @Sendable (Script) -> Script) async -> Script? = { _ in nil }
    /// AI re-analysis from corrected facts + 背景; returns the updated script.
    var onReanalyze: () async -> Script? = { nil }

    @State private var isEditing = false
    @State private var editDraft = ""
    @State private var shareParcel: ShareParcel?
    // The latest edited/re-analyzed script — `item` is an immutable row copy, so edits display
    // from this override until the list refreshes.
    @State private var revisedScript: Script?
    @State private var isReanalyzing = false
    @State private var isEditingContext = false
    @State private var contextDraft = ""
    @State private var isEditingFacts = false
    @State private var factsDraft = ScriptFactsDraft()
    @State private var editingShot: StoryboardShot?

    private var displayedBreakdown: Script? {
        revisedScript ?? item.breakdown
    }

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

            if let breakdown = displayedBreakdown {
                // A degraded breakdown (vision failed → transcript-only, bad-JSON fallback, partial
                // deep coverage) must be visibly marked — it used to look identical to a full 拆解.
                if let note = breakdown.degradationNote, !note.isEmpty {
                    Section {
                        Label {
                            Text(note)
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text("这是降级结果，非完整拆解。可删除后重新导入，或修复设置后重试。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("画面理解未完全生效")
                    }
                }

                // Human-in-the-loop correction: the user supplies the 梗/题材 the model can't know
                // and/or fixes facts, then AI re-derives the analysis on top of them.
                Section {
                    if let context = breakdown.userContext, !context.isEmpty {
                        Text(context)
                            .font(.footnote)
                            .textSelection(.enabled)
                    } else {
                        Text("补充这条视频的梗/题材/人物背景，AI 会按你的背景重新理解这条视频。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        contextDraft = breakdown.userContext ?? ""
                        isEditingContext = true
                    } label: {
                        Label(breakdown.userContext?.isEmpty == false ? "编辑背景" : "补充背景", systemImage: "square.and.pencil")
                    }
                    Button {
                        factsDraft = ScriptFactsDraft(script: breakdown)
                        isEditingFacts = true
                    } label: {
                        Label("编辑标题/摘要/剧情点", systemImage: "list.bullet.rectangle")
                    }
                    Button {
                        Task {
                            isReanalyzing = true
                            defer { isReanalyzing = false }
                            if let updated = await onReanalyze() {
                                revisedScript = updated
                            }
                        }
                    } label: {
                        if isReanalyzing {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("重新分析中…")
                            }
                        } else {
                            Label("AI 重新分析（按台词+字幕+背景重写爆点结构）", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(isReanalyzing)
                } header: {
                    Text("背景与订正")
                }

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
                            ShotRowView(
                                shot: shot,
                                videoURL: breakdownVideoURL,
                                onEditNarration: { editingShot = shot }
                            )
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
            if canAsk {
                ToolbarItem(placement: .automatic) {
                    Button {
                        onAskAboutClip(item)
                    } label: {
                        Label("问这条", systemImage: "questionmark.bubble")
                    }
                    .accessibilityLabel("只问这条内容")
                }
            }
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
                        if breakdownVideoURL != nil, let shots = displayedBreakdown?.shots, !shots.isEmpty {
                            Button {
                                Task { await prepareShareWithFrames(shots) }
                            } label: {
                                Label("分享（附分镜截图）", systemImage: "photo.on.rectangle.angled")
                            }
                        }
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
        .sheet(isPresented: $isEditingContext) {
            UserContextEditSheet(text: contextDraft) { newText in
                Task {
                    let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let updated = await onUpdateScript({ $0.withUserContext(trimmed.isEmpty ? nil : trimmed) }) {
                        revisedScript = updated
                    }
                }
            }
        }
        .sheet(isPresented: $isEditingFacts) {
            ScriptFactsEditSheet(draft: factsDraft) { draft in
                Task {
                    if let updated = await onUpdateScript({ draft.applied(to: $0) }) {
                        revisedScript = updated
                    }
                }
            }
        }
        .sheet(item: $editingShot) { shot in
            ShotNarrationEditSheet(shot: shot) { newNarration in
                Task {
                    let index = shot.index
                    if let updated = await onUpdateScript({ Self.replacingNarration($0, shotIndex: index, narration: newNarration) }) {
                        revisedScript = updated
                    }
                }
            }
        }
        #if os(iOS)
        .sheet(item: $shareParcel) { parcel in
            ShareSheet(items: parcel.items)
        }
        #endif
    }

    /// Text/URL clips carry their content as editable body text; video breakdowns are structured
    /// scripts (their 台词 is auto-corrected during analysis), so they aren't free-text editable here.
    private var canEditContent: Bool {
        item.breakdown == nil && !(item.bodyText ?? "").isEmpty
    }

    /// Only indexed clips have retrievable content, so only they can be asked about.
    private var canAsk: Bool {
        item.state == .indexed
    }

    private nonisolated static func replacingNarration(_ script: Script, shotIndex: Int, narration: String) -> Script {
        let trimmed = narration.trimmingCharacters(in: .whitespacesAndNewlines)
        let shots = script.shots.map { shot -> StoryboardShot in
            guard shot.index == shotIndex else { return shot }
            return StoryboardShot(
                index: shot.index,
                startSeconds: shot.startSeconds,
                endSeconds: shot.endSeconds,
                narration: trimmed.isEmpty ? nil : trimmed,
                visualDescription: shot.visualDescription,
                pacingNote: shot.pacingNote,
                onScreenText: shot.onScreenText
            )
        }
        return Script(
            id: script.id,
            videoSourceID: script.videoSourceID,
            title: script.title,
            summary: script.summary,
            shots: shots,
            createdAt: script.createdAt,
            hookStructure: script.hookStructure,
            visualElements: script.visualElements,
            characters: script.characters,
            degradationNote: script.degradationNote,
            userContext: script.userContext
        )
    }

    /// The local video file backing this breakdown, used to render per-shot frame thumbnails. Video
    /// clips store their imported copy as the source URL; nil for web/text clips (no thumbnails).
    private var breakdownVideoURL: URL? {
        guard let url = item.sourceURL, url.isFileURL else { return nil }
        return url
    }

    #if os(iOS)
    /// Bundles the handoff script text with one frame per shot so 投喂 can carry reference stills
    /// (for 豆包/即梦) alongside the text. Frames are decoded on demand from the local video.
    private func prepareShareWithFrames(_ shots: [StoryboardShot]) async {
        var items: [Any] = [item.handoffText]
        if let url = breakdownVideoURL {
            for shot in shots.sorted(by: { $0.index < $1.index }) {
                if let image = await ShotThumbnailCache.shared.load(url: url, seconds: shot.startSeconds, maxSize: 1080) {
                    items.append(image)
                }
            }
        }
        shareParcel = ShareParcel(items: items)
    }
    #endif

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

/// Editable understanding-facts of a breakdown (title/summary/爆点结构 fields).
private struct ScriptFactsDraft {
    var title = ""
    var summary = ""
    var openingHook = ""
    var retentionDevices = ""
    var payoff = ""
    var callToAction = ""
    var whyItWorks = ""

    init() {}

    init(script: Script) {
        title = script.title
        summary = script.summary
        openingHook = script.hookStructure?.openingHook ?? ""
        retentionDevices = script.hookStructure?.retentionDevices.joined(separator: "、") ?? ""
        payoff = script.hookStructure?.payoff ?? ""
        callToAction = script.hookStructure?.callToAction ?? ""
        whyItWorks = script.hookStructure?.whyItWorks ?? ""
    }

    func applied(to script: Script) -> Script {
        let devices = retentionDevices
            .split(whereSeparator: { $0 == "、" || $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let hookFieldsEmpty = openingHook.trimmingCharacters(in: .whitespaces).isEmpty
            && devices.isEmpty
            && payoff.trimmingCharacters(in: .whitespaces).isEmpty
            && callToAction.trimmingCharacters(in: .whitespaces).isEmpty
            && whyItWorks.trimmingCharacters(in: .whitespaces).isEmpty
        let hook: HookAnalysis? = hookFieldsEmpty ? script.hookStructure : HookAnalysis(
            openingHook: openingHook.trimmingCharacters(in: .whitespacesAndNewlines),
            retentionDevices: devices,
            payoff: payoff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : payoff.trimmingCharacters(in: .whitespacesAndNewlines),
            callToAction: callToAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : callToAction.trimmingCharacters(in: .whitespacesAndNewlines),
            whyItWorks: whyItWorks.trimmingCharacters(in: .whitespacesAndNewlines),
            hookType: script.hookStructure?.hookType ?? .other
        )
        return Script(
            id: script.id,
            videoSourceID: script.videoSourceID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? script.title : title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? script.summary : summary.trimmingCharacters(in: .whitespacesAndNewlines),
            shots: script.shots,
            createdAt: script.createdAt,
            hookStructure: hook,
            visualElements: script.visualElements,
            characters: script.characters,
            degradationNote: script.degradationNote,
            userContext: script.userContext
        )
    }
}

private struct UserContextEditSheet: View {
    @State var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                } footer: {
                    Text("写下这条视频的梗、题材、真实人物/战队等背景。「AI 重新分析」会基于它重新理解爆点，重拆也会带上它。")
                }
            }
            .navigationTitle("视频背景")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(text)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ScriptFactsEditSheet: View {
    @State var draft: ScriptFactsDraft
    let onSave: (ScriptFactsDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("标题与摘要") {
                    TextField("标题", text: $draft.title)
                    TextField("摘要", text: $draft.summary, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    TextField("钩子（前 3 秒）", text: $draft.openingHook, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("留人手法（、分隔）", text: $draft.retentionDevices, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("爆点/反转", text: $draft.payoff, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("CTA（可空）", text: $draft.callToAction, axis: .vertical)
                        .lineLimit(1...2)
                    TextField("为什么成立", text: $draft.whyItWorks, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("剧情点（爆点结构）")
                } footer: {
                    Text("改完会重建检索索引，问答与洞察范式都会基于修正后的内容。")
                }
            }
            .navigationTitle("编辑剧本信息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ShotNarrationEditSheet: View {
    let shot: StoryboardShot
    let onSave: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(shot: StoryboardShot, onSave: @escaping (String) -> Void) {
        self.shot = shot
        self.onSave = onSave
        _text = State(initialValue: shot.narration ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("台词") {
                    TextEditor(text: $text)
                        .frame(minHeight: 100)
                }
                if !shot.onScreenText.isEmpty {
                    Section {
                        Text(shot.onScreenText.joined(separator: " / "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            text = shot.onScreenText.joined(separator: "，")
                        } label: {
                            Label("用字幕填入", systemImage: "text.insert")
                        }
                    } header: {
                        Text("字幕参考")
                    } footer: {
                        Text("字幕是作者自己压的，通常比语音识别准。")
                    }
                }
            }
            .navigationTitle("订正分镜 \(shot.index + 1) 台词")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(text)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
    var videoURL: URL? = nil
    var onEditNarration: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            #if os(iOS)
            if let videoURL {
                // Midpoint, not startSeconds: a shot's first frame often catches the cut/transition
                // (mouth closed, motion blur) — the middle is the representative moment.
                ShotThumbnail(
                    videoURL: videoURL,
                    seconds: (shot.startSeconds + max(shot.startSeconds, shot.endSeconds)) / 2,
                    shotIndex: shot.index
                )
            }
            #endif

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("分镜 \(shot.index + 1)  \(timeRange)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let onEditNarration {
                        Button(action: onEditNarration) {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("订正这一镜的台词")
                    }
                }
                if let narration = shot.narration, !narration.isEmpty {
                    Text("台词: \(narration)").font(.subheadline)
                }
                if !shot.onScreenText.isEmpty {
                    Text("字幕: \(shot.onScreenText.joined(separator: " / "))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !shot.visualDescription.isEmpty {
                    Text("画面: \(shot.visualDescription)").font(.subheadline)
                }
                if let pacing = shot.pacingNote, !pacing.isEmpty {
                    Text("节奏: \(pacing)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
        }
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

#if os(iOS)
/// A per-shot frame thumbnail, decoded on demand from the local video at the shot's start time and
/// cached so re-scrolling the storyboard doesn't re-decode. Tap to view the frame full-screen.
private struct ShotThumbnail: View {
    let videoURL: URL
    let seconds: Double
    let shotIndex: Int
    @State private var image: UIImage?
    @State private var isEnlarged = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: 60, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { if image != nil { isEnlarged = true } }
        .task(id: seconds) {
            image = await ShotThumbnailCache.shared.load(url: videoURL, seconds: seconds)
        }
        .fullScreenCover(isPresented: $isEnlarged) {
            ShotFramePreview(videoURL: videoURL, seconds: seconds, shotIndex: shotIndex)
        }
        .accessibilityLabel("分镜 \(shotIndex + 1) 画面")
    }
}

/// Full-screen frame preview, regenerated at higher resolution than the row thumbnail.
private struct ShotFramePreview: View {
    let videoURL: URL
    let seconds: Double
    let shotIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding()
                    }
                    .accessibilityLabel("关闭")
                }
                Spacer()
            }
        }
        .task {
            image = await ShotThumbnailCache.shared.load(url: videoURL, seconds: seconds, maxSize: 1280)
        }
    }
}

/// Small in-memory cache + decoder for video frame thumbnails. Keyed by (url, ~0.1s, size) so a
/// row thumbnail and its full-screen preview are cached independently.
@MainActor
private final class ShotThumbnailCache {
    static let shared = ShotThumbnailCache()
    private var cache: [String: UIImage] = [:]

    func load(url: URL, seconds: Double, maxSize: CGFloat = 320) async -> UIImage? {
        let key = "\(url.absoluteString)#\(Int(seconds * 10))@\(Int(maxSize))"
        if let cached = cache[key] { return cached }
        let image = await Self.decode(url: url, seconds: seconds, maxSize: maxSize)
        if let image { cache[key] = image }
        return image
    }

    private static func decode(url: URL, seconds: Double, maxSize: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
#endif

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

/// A prepared share payload (script text + shot stills) identified for `.sheet(item:)`.
private struct ShareParcel: Identifiable {
    let id = UUID()
    let items: [Any]
}

#if os(iOS)
/// Bridges UIActivityViewController so 投喂 can share mixed content (text + reference stills).
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
