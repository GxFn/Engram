import Foundation

public enum ScriptRendering {
    public static func indexableText(_ script: Script) -> String {
        var blocks = [script.title, script.summary].filter { !$0.trimmedForIndexing.isEmpty }

        if let hookBlock = hookStructureBlock(script.hookStructure) {
            blocks.append(hookBlock)
        }

        if let charactersBlock = charactersBlock(script.characters) {
            blocks.append(charactersBlock)
        }

        if let visualElementsBlock = visualElementsBlock(script.visualElements) {
            blocks.append(visualElementsBlock)
        }

        for shot in script.shots.sorted(by: { $0.index < $1.index }) {
            var lines = [
                "## 分镜 \(shot.index + 1) (\(formatSeconds(shot.startSeconds))–\(formatSeconds(shot.endSeconds)))"
            ]

            if let narration = shot.narration?.trimmedForIndexing, !narration.isEmpty {
                lines.append("台词: \(narration)")
            }

            lines.append("画面: \(shot.visualDescription.trimmedForIndexing)")

            if let pacingNote = shot.pacingNote?.trimmedForIndexing, !pacingNote.isEmpty {
                lines.append("节奏: \(pacingNote)")
            }

            blocks.append(lines.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n")
    }

    private static func hookStructureBlock(_ hook: HookAnalysis?) -> String? {
        guard let hook else {
            return nil
        }

        var lines = [
            "## 爆点结构",
            "钩子: \(hook.openingHook.trimmedForIndexing)",
            "留人: \(hook.retentionDevices.trimmedJoinedForIndexing)",
        ]

        if let payoff = hook.payoff?.trimmedForIndexing, !payoff.isEmpty {
            lines.append("爆点: \(payoff)")
        }

        if let callToAction = hook.callToAction?.trimmedForIndexing, !callToAction.isEmpty {
            lines.append("CTA: \(callToAction)")
        }

        lines.append("为什么成立: \(hook.whyItWorks.trimmedForIndexing)")

        return lines.joined(separator: "\n")
    }

    private static func charactersBlock(_ characters: [String]) -> String? {
        let profiles = characters.map(\.trimmedForIndexing).filter { !$0.isEmpty }
        guard !profiles.isEmpty else {
            return nil
        }

        return "## 人物\n" + profiles.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func visualElementsBlock(_ elements: [String]) -> String? {
        let labels = elements.trimmedJoinedForIndexing
        guard !labels.isEmpty else {
            return nil
        }

        return "## 视觉元素\n标签: \(labels)"
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        let safeSeconds = seconds.isFinite ? seconds : 0
        let sign = safeSeconds < 0 ? "-" : ""
        let roundedTenths = Int((abs(safeSeconds) * 10).rounded())
        let wholeSeconds = roundedTenths / 10
        let tenths = roundedTenths % 10

        if tenths == 0 {
            return "\(sign)\(wholeSeconds)s"
        }

        return "\(sign)\(wholeSeconds).\(tenths)s"
    }
}

private extension String {
    var trimmedForIndexing: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array where Element == String {
    var trimmedJoinedForIndexing: String {
        map(\.trimmedForIndexing)
            .filter { !$0.isEmpty }
            .joined(separator: "、")
    }
}
