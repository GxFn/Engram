import Foundation
import MetricsKit

public enum MarkdownExporter {
    public static func table(for runs: [BenchRun]) -> String {
        ([header] + runs.map(tableRow)).joined(separator: "\n")
    }

    public static func retrievalTable(for run: RetrievalEvalRun) -> String {
        ([retrievalHeader] + run.strategyResults.map(retrievalTableRow)).joined(separator: "\n")
    }

    public static var header: String {
        "| Date | Engine | Model | TTFT | tok/s | Output | Peak memory | Thermal | Low power |\n| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |"
    }

    public static var retrievalHeader: String {
        "| Strategy | Questions | Recall@8 | MRR |\n| --- | ---: | ---: | ---: |"
    }

    public static func tableRow(for run: BenchRun) -> String {
        let ttft = run.sampleValue(.firstTokenLatencyMillis).map { "\(format($0, digits: 0)) ms" } ?? "-"
        let tokensPerSecond = run.sampleValue(.tokensPerSecond).map { format($0, digits: 1) } ?? "-"
        let outputTokens = run.sampleValue(.outputTokenCount).map { format($0, digits: 0) } ?? "-"
        let peakMemory = run.sampleValue(.peakMemoryBytes).map { bytes in
            "\(format(bytes / 1_048_576, digits: 1)) MB"
        } ?? "-"

        return "| \(dateString(run.startedAt)) | \(run.engineID) | \(run.modelID) | \(ttft) | \(tokensPerSecond) | \(outputTokens) | \(peakMemory) | \(run.environment.thermalState) | \(run.environment.lowPowerMode ? "yes" : "no") |"
    }

    public static func retrievalTableRow(for result: RetrievalEvalStrategyResult) -> String {
        "| \(result.strategy.displayName) | \(result.questionCount) | \(format(result.recallAt8, digits: 2)) | \(format(result.mrr, digits: 2)) |"
    }

    private static func dateString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func format(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}
