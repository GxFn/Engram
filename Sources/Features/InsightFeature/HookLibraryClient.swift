import Foundation
import ScriptCore

/// Closures the shell injects so InsightFeature stays free of Infrastructure: hooks are derived
/// from the breakdown store, favorites are persisted by the shell.
public struct HookLibraryClient: Sendable {
    public let loadHooks: @Sendable () async -> [HookEntry]
    public let setFavorite: @Sendable (_ clipID: String, _ isFavorite: Bool) async -> Void

    public init(
        loadHooks: @escaping @Sendable () async -> [HookEntry] = { [] },
        setFavorite: @escaping @Sendable (_ clipID: String, _ isFavorite: Bool) async -> Void = { _, _ in }
    ) {
        self.loadHooks = loadHooks
        self.setFavorite = setFavorite
    }

    public static let empty = HookLibraryClient()
}
