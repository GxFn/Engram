import Foundation

public enum ScriptRendering {
    public static func indexableText(_ script: Script) -> String {
        var blocks = [script.title, script.summary].filter { !$0.trimmedForIndexing.isEmpty }

        for shot in script.shots.sorted(by: { $0.index < $1.index }) {
            var lines = [
                "Shot \(shot.index + 1) (\(formatSeconds(shot.startSeconds))-\(formatSeconds(shot.endSeconds)))"
            ]

            if let narration = shot.narration?.trimmedForIndexing, !narration.isEmpty {
                lines.append("Narration: \(narration)")
            }

            lines.append("Visual: \(shot.visualDescription.trimmedForIndexing)")

            if let pacingNote = shot.pacingNote?.trimmedForIndexing, !pacingNote.isEmpty {
                lines.append("Pacing: \(pacingNote)")
            }

            blocks.append(lines.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n")
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
