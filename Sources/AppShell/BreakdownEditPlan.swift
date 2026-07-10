import Foundation
import ScriptCore

/// A model-emitted correction to a focused breakdown, decoded from the chat's `<engram-edit>` block.
/// Lenient by design: only the keys present are applied; anything unparseable throws so the chat can
/// surface "修正未能应用" instead of silently doing nothing.
struct BreakdownEditPlan: Decodable {
    struct NarrationFix: Decodable {
        /// 1-based 分镜 number as displayed in the UI/prompt (mapped to StoryboardShot.index + 1).
        let shot: Int
        let text: String
    }

    struct HookEdit: Decodable {
        let openingHook: String?
        let hookType: String?
        let retentionDevices: [String]?
        let payoff: String?
        let callToAction: String?
        let whyItWorks: String?
    }

    let note: String?
    let userContext: String?
    let title: String?
    let summary: String?
    let hook: HookEdit?
    let narration: [NarrationFix]?

    static func decode(fromJSON raw: String) throws -> BreakdownEditPlan {
        guard let data = raw.data(using: .utf8) else {
            throw BreakdownEditError.unparseable
        }
        // The block content should be bare JSON, but tolerate stray prose/fences around it.
        if let plan = try? JSONDecoder().decode(BreakdownEditPlan.self, from: data) {
            return plan
        }
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let sliced = String(raw[start ... end]).data(using: .utf8),
              let plan = try? JSONDecoder().decode(BreakdownEditPlan.self, from: sliced)
        else {
            throw BreakdownEditError.unparseable
        }
        return plan
    }

    /// True when the plan carries at least one applicable change.
    var isSubstantive: Bool {
        userContext != nil || title != nil || summary != nil || hook != nil
            || !(narration ?? []).isEmpty
    }

    /// Applies the present keys onto the script. Field semantics: replace when non-empty; hook is
    /// merged field-by-field over the existing 爆点结构; narration fixes address shots by displayed
    /// number (index+1) and silently skip unknown numbers.
    func applied(to script: Script) -> Script {
        let mergedHook: HookAnalysis?
        if let hook {
            let base = script.hookStructure
            mergedHook = HookAnalysis(
                openingHook: nonEmpty(hook.openingHook) ?? base?.openingHook ?? "",
                retentionDevices: hook.retentionDevices ?? base?.retentionDevices ?? [],
                payoff: nonEmpty(hook.payoff) ?? base?.payoff,
                callToAction: nonEmpty(hook.callToAction) ?? base?.callToAction,
                whyItWorks: nonEmpty(hook.whyItWorks) ?? base?.whyItWorks ?? "",
                hookType: hook.hookType.map(HookType.from) ?? base?.hookType ?? .other
            )
        } else {
            mergedHook = script.hookStructure
        }

        let fixesByIndex = Dictionary(
            (narration ?? []).map { ($0.shot - 1, $0.text) },
            uniquingKeysWith: { _, last in last }
        )
        let shots = script.shots.map { shot -> StoryboardShot in
            guard let fixed = fixesByIndex[shot.index] else { return shot }
            let trimmed = fixed.trimmingCharacters(in: .whitespacesAndNewlines)
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
            title: nonEmpty(title) ?? script.title,
            summary: nonEmpty(summary) ?? script.summary,
            shots: shots,
            createdAt: script.createdAt,
            hookStructure: mergedHook,
            visualElements: script.visualElements,
            characters: script.characters,
            degradationNote: script.degradationNote,
            userContext: nonEmpty(userContext) ?? script.userContext
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

enum BreakdownEditError: Error, LocalizedError {
    case unparseable
    case nothingToApply
    case breakdownMissing

    var errorDescription: String? {
        switch self {
        case .unparseable: "修正内容无法解析。"
        case .nothingToApply: "修正块里没有可应用的修改。"
        case .breakdownMissing: "这条内容没有可修正的拆解。"
        }
    }
}

/// Renders a focused breakdown's current facts for the chat system prompt — compact and 1-based,
/// matching the edit protocol the model replies with.
enum BreakdownFactsRendering {
    static func facts(for script: Script) -> String {
        var lines: [String] = []
        lines.append("标题：\(script.title)")
        lines.append("摘要：\(script.summary)")
        if let context = script.userContext, !context.isEmpty {
            lines.append("背景（用户提供）：\(context)")
        }
        if let hook = script.hookStructure {
            lines.append("钩子：\(hook.openingHook)｜类型：\(hook.hookType.displayName)｜留人：\(hook.retentionDevices.joined(separator: "、"))｜爆点：\(hook.payoff ?? "（空）")｜CTA：\(hook.callToAction ?? "（空）")｜为什么成立：\(hook.whyItWorks)")
        }
        if !script.characters.isEmpty {
            lines.append("人物：\(script.characters.joined(separator: "；"))")
        }
        for shot in script.shots.sorted(by: { $0.index < $1.index }) {
            let narration = shot.narration?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let captions = shot.onScreenText.joined(separator: " / ")
            var parts = ["分镜\(shot.index + 1) [\(String(format: "%.1f", shot.startSeconds))-\(String(format: "%.1f", shot.endSeconds))s]"]
            if !narration.isEmpty { parts.append("台词:\(narration)") }
            if !captions.isEmpty { parts.append("字幕:\(captions)") }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}
