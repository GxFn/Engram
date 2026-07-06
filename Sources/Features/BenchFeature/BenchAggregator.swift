import EngineKit
import Foundation
import MetricsKit

public enum BenchAggregator {
    public static func samples(
        from results: [BenchRoundResult],
        peakMemoryBytes: UInt64
    ) -> [BenchSample] {
        [
            BenchSample(
                metric: BenchMetric.firstTokenLatencyMillis.rawValue,
                value: median(results.compactMap(\.metrics.firstTokenLatencyMillis)) ?? 0,
                unit: "ms"
            ),
            BenchSample(
                metric: BenchMetric.tokensPerSecond.rawValue,
                value: median(results.compactMap(\.metrics.tokensPerSecond)) ?? 0,
                unit: "tok/s"
            ),
            BenchSample(
                metric: BenchMetric.outputTokenCount.rawValue,
                value: median(results.map { Double($0.metrics.outputTokenCount) }) ?? 0,
                unit: "tokens"
            ),
            BenchSample(
                metric: BenchMetric.peakMemoryBytes.rawValue,
                value: Double(peakMemoryBytes),
                unit: "bytes"
            ),
        ]
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }

        return sorted[middle]
    }
}
