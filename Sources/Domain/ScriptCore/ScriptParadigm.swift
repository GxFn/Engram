import Foundation

/// A reusable script paradigm (剧本范式, v6) distilled from several 分镜剧本: the common, reusable
/// template behind a batch of breakdowns — a scaffold you can apply to your next video, not just an
/// analysis. Derived from breakdowns; persisted by the shell so it can be revisited, applied, or
/// deleted.
public struct ScriptParadigm: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let applicableScene: String
    /// Source breakdowns this paradigm was distilled from (the evidence trail).
    public let sourceClipIDs: [String]
    public let createdAt: Date
    /// The structural skeleton: opening hook → retention → payoff → close, each a reusable pattern.
    public let beats: [ParadigmBeat]
    /// Recurring key elements across the batch (人物 / 场景 / 节奏 / 风格).
    public let keyElements: [String]

    public init(
        id: String,
        name: String,
        applicableScene: String,
        sourceClipIDs: [String],
        createdAt: Date,
        beats: [ParadigmBeat],
        keyElements: [String]
    ) {
        self.id = id
        self.name = name
        self.applicableScene = applicableScene
        self.sourceClipIDs = sourceClipIDs
        self.createdAt = createdAt
        self.beats = beats
        self.keyElements = keyElements
    }
}

public struct ParadigmBeat: Sendable, Hashable, Codable, Identifiable {
    /// Stage name, e.g. 开场钩子 / 留人 / 爆点 / 收尾.
    public let stage: String
    /// The reusable pattern for this stage.
    public let pattern: String
    /// Why it works / how to execute it.
    public let note: String

    public var id: String { stage }

    public init(stage: String, pattern: String, note: String) {
        self.stage = stage
        self.pattern = pattern
        self.note = note
    }
}

/// Compact per-breakdown material fed to the paradigm distiller — built by the shell from a Script
/// so the composer never touches raw video / full text (keeps distillation cheap). Carries every
/// structured field the paradigm's beats/keyElements are asked to generalize over (爆点/CTA/人物/
/// 视觉/代表分镜) — with only hook-opening material the model had to fabricate half the skeleton.
public struct ParadigmSource: Sendable, Hashable {
    public let clipID: String
    public let title: String
    public let summary: String
    public let hook: HookAnalysis?
    public let shotCount: Int
    public let characters: [String]
    public let visualElements: [String]
    /// A few representative shots (first/middle/last) as "台词|字幕" lines, trimmed.
    public let sampleShotLines: [String]

    public init(
        clipID: String,
        title: String,
        summary: String,
        hook: HookAnalysis?,
        shotCount: Int,
        characters: [String] = [],
        visualElements: [String] = [],
        sampleShotLines: [String] = []
    ) {
        self.clipID = clipID
        self.title = title
        self.summary = summary
        self.hook = hook
        self.shotCount = shotCount
        self.characters = characters
        self.visualElements = visualElements
        self.sampleShotLines = sampleShotLines
    }

    public static func from(clipID: String, title: String, script: Script) -> ParadigmSource {
        ParadigmSource(
            clipID: clipID,
            title: title,
            summary: script.summary,
            hook: script.hookStructure,
            shotCount: script.shots.count,
            characters: script.characters,
            visualElements: script.visualElements,
            sampleShotLines: representativeShotLines(script.shots)
        )
    }

    /// First / middle / last shot as compact grounding lines — enough for the distiller to see the
    /// actual opening, mid-point and close instead of inventing them.
    static func representativeShotLines(_ shots: [StoryboardShot]) -> [String] {
        let sorted = shots.sorted { $0.index < $1.index }
        guard !sorted.isEmpty else { return [] }
        var picks: [StoryboardShot] = [sorted[0]]
        if sorted.count > 2 { picks.append(sorted[sorted.count / 2]) }
        if sorted.count > 1, let last = sorted.last { picks.append(last) }

        return picks.map { shot in
            let narration = (shot.narration ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let caption = shot.onScreenText.first ?? ""
            let text = [String(narration.prefix(40)), String(caption.prefix(20))]
                .filter { !$0.isEmpty }
                .joined(separator: "｜字幕:")
            return "分镜\(shot.index + 1): \(text.isEmpty ? "（无台词）" : text)"
        }
    }
}
