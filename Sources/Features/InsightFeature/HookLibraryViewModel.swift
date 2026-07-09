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
