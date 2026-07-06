import ClipCore
import Observation
import SwiftUI

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
        indexPreview: String?
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
    }
}

public struct MemoryClient: Sendable {
    public let loadItems: @Sendable () async throws -> [MemoryClip]
    public let digestPending: @Sendable () async throws -> Void
    public let retryClip: @Sendable (String) async throws -> Void

    public init(
        loadItems: @escaping @Sendable () async throws -> [MemoryClip],
        digestPending: @escaping @Sendable () async throws -> Void,
        retryClip: @escaping @Sendable (String) async throws -> Void
    ) {
        self.loadItems = loadItems
        self.digestPending = digestPending
        self.retryClip = retryClip
    }

    public static let empty = MemoryClient(
        loadItems: { [] },
        digestPending: {},
        retryClip: { _ in }
    )
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

    public func refresh() async {
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
}

/// Memory surface — the app-side digest status timeline.
public struct MemoryView: View {
    @State private var viewModel: MemoryViewModel

    public init(viewModel: MemoryViewModel = MemoryViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Group {
            if viewModel.items.isEmpty {
                ContentUnavailableView(
                    "No clips yet",
                    systemImage: "tray.full"
                )
            } else {
                List(viewModel.items) { item in
                    NavigationLink {
                        MemoryDetailView(item: item) {
                            Task { await viewModel.retry(item) }
                        }
                    } label: {
                        MemoryRow(item: item)
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
        .navigationTitle("Memory")
        .task {
            await viewModel.digestAndRefresh()
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
    let retry: () -> Void

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

            if let bodyText = item.bodyText, !bodyText.isEmpty {
                Section("Original") {
                    Text(bodyText)
                        .textSelection(.enabled)
                }
            }

            if let indexPreview = item.indexPreview, !indexPreview.isEmpty {
                Section("Index Preview") {
                    Text(indexPreview)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(item.title)
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
        case .fetching, .indexing:
            .blue
        case .queued:
            .secondary
        }
    }

    private var background: Color {
        foreground.opacity(0.14)
    }
}
