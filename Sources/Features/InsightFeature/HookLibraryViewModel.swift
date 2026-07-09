import Foundation
import Observation
import ScriptCore

@MainActor
@Observable
public final class HookLibraryViewModel {
    public private(set) var hooks: [HookEntry] = []
    public private(set) var isLoading = false
    public var searchText = ""
    /// nil = all types.
    public var selectedType: HookType?
    public var favoritesOnly = false

    @ObservationIgnored private let client: HookLibraryClient

    public init(client: HookLibraryClient = .empty) {
        self.client = client
    }

    /// The library after applying type / favorite / keyword filters.
    public var filtered: [HookEntry] {
        hooks.filter { hook in
            (selectedType == nil || hook.hookType == selectedType)
                && (!favoritesOnly || hook.isFavorite)
                && hook.matches(searchText)
        }
    }

    /// Hook types that actually appear in the library, in canonical order — drives the filter chips.
    public var presentTypes: [HookType] {
        let present = Set(hooks.map(\.hookType))
        return HookType.allCases.filter { present.contains($0) }
    }

    public var favoriteCount: Int {
        hooks.reduce(0) { $0 + ($1.isFavorite ? 1 : 0) }
    }

    public var totalHooks: Int {
        hooks.count
    }

    // MARK: - Deterministic dashboard (P2): pure aggregates over the library, no LLM.

    public struct TypeCount: Identifiable, Sendable, Hashable {
        public let type: HookType
        public let count: Int
        public var id: String { type.rawValue }
    }

    public struct LabelCount: Identifiable, Sendable, Hashable {
        public let label: String
        public let count: Int
        public var id: String { label }
    }

    /// Hook-type distribution, most frequent first — the shape of your library.
    public var typeDistribution: [TypeCount] {
        let counts = Dictionary(grouping: hooks, by: \.hookType).mapValues(\.count)
        var result: [TypeCount] = []
        for type in HookType.allCases {
            if let count = counts[type] {
                result.append(TypeCount(type: type, count: count))
            }
        }
        return result.sorted { $0.count > $1.count }
    }

    /// Most-used retention devices across the whole library.
    public func topRetentionDevices(limit: Int = 8) -> [LabelCount] {
        var counts: [String: Int] = [:]
        for hook in hooks {
            for device in hook.retentionDevices {
                let trimmed = device.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    counts[trimmed, default: 0] += 1
                }
            }
        }
        var labelCounts = counts.map { LabelCount(label: $0.key, count: $0.value) }
        labelCounts.sort { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.label < rhs.label
        }
        return Array(labelCounts.prefix(limit))
    }

    public var timeSpanText: String? {
        let dates = hooks.map(\.createdAt)
        guard let earliest = dates.min(), let latest = dates.max(), earliest != latest else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: earliest)) – \(formatter.string(from: latest))"
    }

    public func load() async {
        guard !isLoading else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        hooks = await client.loadHooks()
    }

    public func toggleFavorite(_ hook: HookEntry) async {
        let newValue = !hook.isFavorite
        if let index = hooks.firstIndex(where: { $0.id == hook.id }) {
            hooks[index].isFavorite = newValue // optimistic
        }
        await client.setFavorite(hook.clipID, newValue)
    }
}
