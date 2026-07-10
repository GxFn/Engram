import Foundation

/// Merges per-segment breakdowns from the deep (segmented map-reduce) analysis path into one
/// overall ContentBreakdown. Pure domain logic so the merge is unit-testable without any model.
///
/// Rationale for the merge choices:
/// - shots: concatenate every segment's shots in time order and re-index — this is the deep
///   value, each segment got its own visual attention so the shots cover the whole video.
/// - hookStructure: composed across segments — the opening hook lives in the opening segment, but
///   爆点(payoff)/CTA are usually revealed LATE; taking only the first segment's hook dropped them.
/// - visualElements: union across segments (deduped, capped) — elements accumulate.
/// - title: from the first non-empty segment; summary: all segment summaries joined in time order
///   (a first-segment-only summary described just the opening minutes of a long video).
public enum DeepScriptMerge {
    public static func merge(_ partials: [Script], sourceID: String) -> Script? {
        let ordered = partials.sorted { lhs, rhs in
            (lhs.shots.first?.startSeconds ?? .greatestFiniteMagnitude)
                < (rhs.shots.first?.startSeconds ?? .greatestFiniteMagnitude)
        }
        guard let anchor = ordered.first else { return nil }

        let mergedShots = ordered
            .flatMap(\.shots)
            .sorted { $0.startSeconds < $1.startSeconds }
            .enumerated()
            .map { index, shot in
                StoryboardShot(
                    index: index,
                    startSeconds: shot.startSeconds,
                    endSeconds: shot.endSeconds,
                    narration: shot.narration,
                    visualDescription: shot.visualDescription,
                    pacingNote: shot.pacingNote,
                    onScreenText: shot.onScreenText
                )
            }

        let hook = mergedHook(ordered.compactMap(\.hookStructure))

        let elements = Array(dedupedUnion(ordered.flatMap(\.visualElements)).prefix(12))
        // Characters accumulate across segments too, so a long video keeps one consistent 形象 set.
        let characters = Array(dedupedUnion(ordered.flatMap(\.characters)).prefix(8))

        return Script(
            id: anchor.id,
            videoSourceID: sourceID,
            title: firstNonEmpty(ordered.map(\.title)) ?? anchor.title,
            summary: mergedSummary(ordered.map(\.summary)) ?? anchor.summary,
            shots: mergedShots,
            createdAt: anchor.createdAt,
            hookStructure: hook,
            visualElements: elements,
            characters: characters,
            // Any degraded segment marks the whole merged breakdown.
            degradationNote: ordered.compactMap(\.degradationNote).first,
            userContext: ordered.compactMap(\.userContext).first
        )
    }

    /// Opening-anchored fields (钩子/类型/为什么成立) come from the earliest segment that has them;
    /// 留人手法 union across all segments; 爆点/CTA take the LAST non-empty value — they reveal latest,
    /// so a first-segment-only hook misjudged any video whose payoff lands mid/late.
    static func mergedHook(_ hooks: [HookAnalysis]) -> HookAnalysis? {
        guard let first = hooks.first else { return nil }
        return HookAnalysis(
            openingHook: firstNonEmpty(hooks.map(\.openingHook)) ?? first.openingHook,
            retentionDevices: dedupedUnion(hooks.flatMap(\.retentionDevices)),
            payoff: lastNonEmpty(hooks.compactMap(\.payoff)),
            callToAction: lastNonEmpty(hooks.compactMap(\.callToAction)),
            whyItWorks: firstNonEmpty(hooks.map(\.whyItWorks)) ?? first.whyItWorks,
            hookType: first.hookType
        )
    }

    /// Joins every segment's non-empty summary in time order into a whole-video summary,
    /// terminating each part so the join reads as sentences (no run-ons, no double 句号).
    static func mergedSummary(_ summaries: [String]) -> String? {
        let parts = dedupedUnion(summaries)
        guard !parts.isEmpty else { return nil }
        return parts
            .map { part in
                part.hasSuffix("。") || part.hasSuffix("！") || part.hasSuffix("？") || part.hasSuffix(".")
                    ? part
                    : part + "。"
            }
            .joined()
    }

    private static func dedupedUnion(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    private static func firstNonEmpty(_ values: [String]) -> String? {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func lastNonEmpty(_ values: [String]) -> String? {
        values.last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
