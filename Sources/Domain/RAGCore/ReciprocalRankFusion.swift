/// Fuses the dense (vector) and sparse (BM25) rankings into one list.
/// Pure function by design so retrieval quality is unit-testable without any
/// store backend.
public enum ReciprocalRankFusion {
    /// Standard RRF: score(d) = Σ 1 / (k + rank_i(d)). `k` dampens the
    /// dominance of top ranks; 60 is the conventional constant.
    public static func fuse<ID: Hashable & Comparable & Sendable>(
        rankings: [[ID]],
        k: Double = 60
    ) -> [ID] {
        var scores: [ID: Double] = [:]
        for ranking in rankings {
            for (index, id) in ranking.enumerated() {
                scores[id, default: 0] += 1.0 / (k + Double(index + 1))
            }
        }
        return scores
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key // deterministic tie-break keeps eval runs reproducible
            }
            .map(\.key)
    }
}
