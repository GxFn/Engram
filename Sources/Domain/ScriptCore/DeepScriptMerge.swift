import Foundation

/// Merges per-segment breakdowns from the deep (segmented map-reduce) analysis path into one
/// overall ContentBreakdown. Pure domain logic so the merge is unit-testable without any model.
///
/// Rationale for the merge choices:
/// - shots: concatenate every segment's shots in time order and re-index — this is the deep
///   value, each segment got its own visual attention so the shots cover the whole video.
/// - hookStructure: take the first segment's hook — the opening hook of the video lives in the
///   opening segment.
/// - visualElements: union across segments (deduped, capped) — elements accumulate.
/// - title/summary: from the first non-empty segment — the opening sets up the topic.
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
                    pacingNote: shot.pacingNote
                )
            }

        let hook = ordered.compactMap(\.hookStructure).first

        var seen = Set<String>()
        var elements: [String] = []
        for element in ordered.flatMap(\.visualElements) {
            let trimmed = element.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                elements.append(trimmed)
            }
        }
        elements = Array(elements.prefix(12))

        return Script(
            id: anchor.id,
            videoSourceID: sourceID,
            title: firstNonEmpty(ordered.map(\.title)) ?? anchor.title,
            summary: firstNonEmpty(ordered.map(\.summary)) ?? anchor.summary,
            shots: mergedShots,
            createdAt: anchor.createdAt,
            hookStructure: hook,
            visualElements: elements
        )
    }

    private static func firstNonEmpty(_ values: [String]) -> String? {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
