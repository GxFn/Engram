import Foundation

/// Deterministic backstop for 分镜 pacing: folds a genuine sub-`minSeconds` fragment (e.g. a 0.1s
/// "我" cut off its own sentence) into its **adjacent** neighbour, so noisy ASR splits never survive
/// as their own 分镜 — while leaving legitimate short sentences (the fast-paced 爆款 case) intact.
///
/// Two guards keep it from over-merging: (1) only the incoming shot being a fragment triggers a fold
/// (never "the previous is short too" — that cascaded whole runs of short sentences into one shot);
/// (2) the fragment must be temporally adjacent (`gap <= maxGap`) — a short shot far down the
/// timeline is its own shot, never fused across a gap into a distant one.
///
/// Merging concatenates narration in time order, keeps a non-empty visual description, unions
/// on-screen text, and re-indexes from 0.
public enum ShotMerger {
    public static func merge(
        _ shots: [StoryboardShot],
        minSeconds: Double = 0.35,
        maxGap: Double = 0.4
    ) -> [StoryboardShot] {
        guard shots.count > 1, minSeconds > 0 else { return reindexed(shots) }

        let sorted = shots.sorted { $0.startSeconds < $1.startSeconds }
        var result: [StoryboardShot] = []
        for shot in sorted {
            if let previous = result.last,
               duration(shot) < minSeconds,                                    // genuine fragment
               shot.startSeconds - previous.endSeconds <= maxGap {             // ...and adjacent
                result[result.count - 1] = combine(previous, shot)
            } else {
                result.append(shot)
            }
        }

        // A trailing fragment has no later shot to absorb it — fold it back, but only if adjacent.
        if result.count > 1, duration(result[result.count - 1]) < minSeconds {
            let tail = result[result.count - 1]
            let previous = result[result.count - 2]
            if tail.startSeconds - previous.endSeconds <= maxGap {
                result.removeLast()
                result[result.count - 1] = combine(previous, tail)
            }
        }

        return reindexed(result)
    }

    private static func duration(_ shot: StoryboardShot) -> Double {
        max(0, shot.endSeconds - shot.startSeconds)
    }

    /// `earlier` is the kept shot; `later` is folded into it.
    private static func combine(_ earlier: StoryboardShot, _ later: StoryboardShot) -> StoryboardShot {
        let narration = [earlier.narration, later.narration]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var onScreen = earlier.onScreenText
        for line in later.onScreenText where !onScreen.contains(line) {
            onScreen.append(line)
        }

        let pacing = (earlier.pacingNote?.isEmpty == false) ? earlier.pacingNote : later.pacingNote

        return StoryboardShot(
            index: earlier.index,
            startSeconds: min(earlier.startSeconds, later.startSeconds),
            endSeconds: max(earlier.endSeconds, later.endSeconds),
            narration: narration.isEmpty ? nil : narration,
            visualDescription: earlier.visualDescription.isEmpty ? later.visualDescription : earlier.visualDescription,
            pacingNote: pacing,
            onScreenText: onScreen
        )
    }

    private static func reindexed(_ shots: [StoryboardShot]) -> [StoryboardShot] {
        shots.enumerated().map { index, shot in
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
    }
}
