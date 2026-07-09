import Foundation

/// Hook category carried on each breakdown's `HookAnalysis` and referenced when distilling a
/// 剧本范式. Stored as its stable English rawValue but decoded leniently from either the rawValue
/// or the Chinese display name (the model emits the Chinese label), with anything unknown folding
/// to `.other` so a classifier drift never breaks decode.
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
