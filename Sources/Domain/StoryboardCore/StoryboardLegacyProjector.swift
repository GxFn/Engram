import Foundation
import ScriptCore
import VideoUnderstanding

/// The sole compatibility boundary from the evidence-grounded document to the
/// legacy `Script` consumed by Memory, Ask indexing, Insight, and share flows.
public enum StoryboardLegacyProjector {
    public static func project(_ document: StoryboardDocumentV2, createdAt: Date = Date()) -> Script {
        let byID = Dictionary(uniqueKeysWithValues: document.shots.map { ($0.id, $0) })
        let shots = document.shotGraph.shots.enumerated().map { index, segment in
            let source = byID[segment.id]
            let plan = source?.productionPlan
            let facts = source?.observedFacts.facts ?? []
            let action = plan?.subjectAction ?? firstValue(.action, in: facts)
            let composition = plan?.composition ?? firstValue(.composition, in: facts)
            let visual = [action, composition, plan?.purpose]
                .compactMap { normalized($0) }
                .uniqued()
                .joined(separator: "；")
            let visibleText = [plan?.onScreenCopy]
                .compactMap { normalized($0) }
                + facts.filter { $0.field == .visibleText }.map(\.value)
            return StoryboardShot(
                index: index,
                startSeconds: segment.timeRange.startSeconds,
                endSeconds: segment.timeRange.endSeconds,
                narration: normalized(plan?.dialogueOrVO) ?? firstValue(.audioSummary, in: facts),
                visualDescription: visual.isEmpty ? "未确认画面" : visual,
                pacingNote: normalized(plan?.transition),
                onScreenText: visibleText.uniqued()
            )
        }
        let analysis = document.contentAnalysis
        let hook = analysis.hook.map {
            HookAnalysis(
                openingHook: $0,
                retentionDevices: analysis.retentionDevices,
                payoff: analysis.payoff,
                callToAction: analysis.callToAction,
                whyItWorks: analysis.summary
            )
        }
        return Script(
            id: document.id,
            videoSourceID: document.source.sourceID,
            title: normalized(analysis.title) ?? "视频分镜",
            summary: analysis.summary,
            shots: shots,
            createdAt: createdAt,
            hookStructure: hook,
            visualElements: shots.map(\.visualDescription).filter { $0 != "未确认画面" },
            degradationNote: document.source.degradationNote
        )
    }

    private static func firstValue(_ field: FactField, in facts: [GroundedFact]) -> String? {
        normalized(facts.first { $0.field == field }?.value)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
