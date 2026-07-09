import Foundation

/// Deterministic backstop for 分镜 pacing: folds storyboard shots shorter than `minSeconds` into an
/// adjacent shot, so a noisy ASR split (e.g. a 0.1s "我" cut off its own sentence) never survives as
/// its own 分镜. The prompt asks the VLM not to fragment in the first place; this guarantees it.
///
/// Merging keeps the earlier shot's visual description (a fragment's is usually empty/redundant),
/// concatenates narration in time order, unions on-screen text, and re-indexes from 0.
public enum ShotMerger {
    public static func merge(_ shots: [StoryboardShot], minSeconds: Double = 1.2) -> [StoryboardShot] {
        guard shots.count > 1, minSeconds > 0 else { return reindexed(shots) }

        let sorted = shots.sorted { $0.startSeconds < $1.startSeconds }
        var result: [StoryboardShot] = []
        for shot in sorted {
            if let previous = result.last, duration(previous) < minSeconds || duration(shot) < minSeconds {
                result[result.count - 1] = combine(previous, shot)
            } else {
                result.append(shot)
            }
        }

        // A trailing short shot has no later shot to absorb it during the forward pass — fold it back.
        if result.count > 1, duration(result[result.count - 1]) < minSeconds {
            let tail = result.removeLast()
            result[result.count - 1] = combine(result[result.count - 1], tail)
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
