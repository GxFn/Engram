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
/// so the composer never touches raw video / full text (keeps distillation cheap).
public struct ParadigmSource: Sendable, Hashable {
    public let clipID: String
    public let title: String
    public let summary: String
    public let hook: HookAnalysis?
    public let shotCount: Int

    public init(clipID: String, title: String, summary: String, hook: HookAnalysis?, shotCount: Int) {
        self.clipID = clipID
        self.title = title
        self.summary = summary
        self.hook = hook
        self.shotCount = shotCount
    }

    public static func from(clipID: String, title: String, script: Script) -> ParadigmSource {
        ParadigmSource(
            clipID: clipID,
            title: title,
            summary: script.summary,
            hook: script.hookStructure,
            shotCount: script.shots.count
        )
    }
}
