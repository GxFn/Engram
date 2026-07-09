import Foundation

/// Hook category carried on each breakdown's `HookAnalysis` and referenced when distilling a
/// 剧本范式. Stored as its stable English rawValue but decoded leniently from either the rawValue
/// or the Chinese display name (the model emits the Chinese label), with anything unknown folding
/// to `.other` so a classifier drift never breaks decode.
public enum HookType: String, Sendable, Hashable, CaseIterable {
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
    /// Falls back to substring matching so common variants ("悬念型"、"情绪冲击钩子"、"Suspense") don't
    /// all collapse into `.other` and erase the classification signal.
    public static func from(_ raw: String) -> HookType {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byRaw = HookType(rawValue: trimmed) {
            return byRaw
        }
        if let byName = HookType.allCases.first(where: { $0.displayName == trimmed }) {
            return byName
        }
        let lowered = trimmed.lowercased()
        // Business cases only (.other excluded); no display name is a substring of another, so the
        // first containment hit is unambiguous.
        return HookType.allCases.first { candidate in
            candidate != .other
                && (trimmed.contains(candidate.displayName) || lowered.contains(candidate.rawValue.lowercased()))
        } ?? .other
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
