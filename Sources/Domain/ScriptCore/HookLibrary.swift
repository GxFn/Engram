import Foundation

/// Hook category for the personal hook library (v6). Stored as its stable English rawValue but
/// decoded leniently from either the rawValue or the Chinese display name (the model emits the
/// Chinese label), with anything unknown folding to `.other` so a classifier drift never breaks
/// decode.
public enum HookType: String, Sendable, Hashable, CaseIterable, Identifiable {
    public var id: String { rawValue }

    case suspense
    case resonance
    case contrast
    case painPoint
    case benefitFirst
    case curiosity
    case identity
    case emotionalShock
    case other

    public var displayName: String {
        switch self {
        case .suspense: "悬念"
        case .resonance: "共鸣"
        case .contrast: "反差"
        case .painPoint: "痛点"
        case .benefitFirst: "利益前置"
        case .curiosity: "好奇"
        case .identity: "身份认同"
        case .emotionalShock: "情绪冲击"
        case .other: "其他"
        }
    }

    /// Maps a model-emitted string (Chinese label or English rawValue, possibly noisy) to a case.
    public static func from(_ raw: String) -> HookType {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byRaw = HookType(rawValue: trimmed) {
            return byRaw
        }
        return HookType.allCases.first { $0.displayName == trimmed } ?? .other
    }
}

extension HookType: Codable {
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = HookType.from(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One entry in the personal hook library — the primary opening hook derived from a video
/// breakdown. Single source of truth is the breakdown (`scriptJSON`); this is a derived view, so
/// `id` is the source clip id (one primary hook per breakdown). User state (`isFavorite`) is layered
/// in by the shell from a separate store.
public struct HookEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let clipID: String
    public let clipTitle: String
    public let text: String
    public let hookType: HookType
    public let retentionDevices: [String]
    public let payoff: String?
    public let whyItWorks: String
    public let createdAt: Date
    public var isFavorite: Bool

    public init(
        id: String,
        clipID: String,
        clipTitle: String,
        text: String,
        hookType: HookType,
        retentionDevices: [String],
        payoff: String?,
        whyItWorks: String,
        createdAt: Date,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.clipID = clipID
        self.clipTitle = clipTitle
        self.text = text
        self.hookType = hookType
        self.retentionDevices = retentionDevices
        self.payoff = payoff
        self.whyItWorks = whyItWorks
        self.createdAt = createdAt
        self.isFavorite = isFavorite
    }

    /// Derives the primary hook entry from a breakdown; nil when there is no usable opening hook.
    public static func derive(
        clipID: String,
        clipTitle: String,
        createdAt: Date,
        script: Script,
        isFavorite: Bool = false
    ) -> HookEntry? {
        guard let hook = script.hookStructure else {
            return nil
        }
        let text = hook.openingHook.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        return HookEntry(
            id: clipID,
            clipID: clipID,
            clipTitle: clipTitle,
            text: text,
            hookType: hook.hookType,
            retentionDevices: hook.retentionDevices,
            payoff: hook.payoff?.trimmingCharacters(in: .whitespacesAndNewlines),
            whyItWorks: hook.whyItWorks.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: createdAt,
            isFavorite: isFavorite
        )
    }

    /// Case-insensitive keyword match across the hook text, why-it-works, and retention devices.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return true
        }
        let haystack = ([text, whyItWorks, payoff ?? ""] + retentionDevices).joined(separator: "\n")
        return haystack.localizedCaseInsensitiveContains(q)
    }
}
