import Foundation
import ScriptCore

/// Closures the shell injects so InsightFeature stays free of Infrastructure: hooks are derived
/// from the breakdown store, favorites + insight reports are persisted by the shell, and report
/// generation runs on the active LLM engine.
public struct HookLibraryClient: Sendable {
    public let loadHooks: @Sendable () async -> [HookEntry]
    public let setFavorite: @Sendable (_ clipID: String, _ isFavorite: Bool) async -> Void
    public let generateReport: @Sendable (_ hooks: [HookEntry], _ scopeDescription: String) async -> InsightReport?
    public let loadReports: @Sendable () async -> [InsightReport]
    public let saveReport: @Sendable (InsightReport) async -> Void
    public let deleteReport: @Sendable (_ id: String) async -> Void

    public init(
        loadHooks: @escaping @Sendable () async -> [HookEntry] = { [] },
        setFavorite: @escaping @Sendable (_ clipID: String, _ isFavorite: Bool) async -> Void = { _, _ in },
        generateReport: @escaping @Sendable (_ hooks: [HookEntry], _ scopeDescription: String) async -> InsightReport? = { _, _ in nil },
        loadReports: @escaping @Sendable () async -> [InsightReport] = { [] },
        saveReport: @escaping @Sendable (InsightReport) async -> Void = { _ in },
        deleteReport: @escaping @Sendable (_ id: String) async -> Void = { _ in }
    ) {
        self.loadHooks = loadHooks
        self.setFavorite = setFavorite
        self.generateReport = generateReport
        self.loadReports = loadReports
        self.saveReport = saveReport
        self.deleteReport = deleteReport
    }

    public static let empty = HookLibraryClient()
}
