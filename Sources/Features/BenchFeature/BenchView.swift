import EngineKit
import MetricsKit
import SwiftUI

/// Bench surface — fixed prompt suite, engine/model pickers, result history,
/// Markdown export for the README table. M3 adds the side-by-side dual-engine
/// comparison used in live demos.
public struct BenchView: View {
    @State private var viewModel: BenchViewModel

    public init(
        engine: any LLMEngine,
        model: ModelIdentity,
        generationConfig: GenerationConfig = GenerationConfig(temperature: 0.2, topP: 0.9, maxTokens: 128)
    ) {
        _viewModel = State(initialValue: BenchViewModel(
            engine: engine,
            model: model,
            generationConfig: generationConfig
        ))
    }

    public init(viewModel: BenchViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                controls
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let latestRun = viewModel.latestRun {
                    resultSection(latestRun)
                }
                historySection
            }
            .padding()
        }
        .navigationTitle("Bench")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(viewModel.engineName, systemImage: "cpu")
                .font(.subheadline.weight(.semibold))

            Text(viewModel.modelName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if viewModel.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = viewModel.progress {
                ProgressView(
                    value: Double(progress.completedIterations),
                    total: Double(progress.totalIterations)
                )
                Text("Round \(progress.round) · \(progress.completedIterations)/\(progress.totalIterations)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Button(action: viewModel.run) {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isRunning)

                Button(action: viewModel.stop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isRunning)

                if !viewModel.history.isEmpty {
                    ShareLink(item: viewModel.exportMarkdown) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func resultSection(_ run: BenchRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latest")
                .font(.headline)

            VStack(spacing: 8) {
                BenchMetricRow(title: "TTFT", value: metric(.firstTokenLatencyMillis, in: run, suffix: "ms", digits: 0))
                BenchMetricRow(title: "tok/s", value: metric(.tokensPerSecond, in: run, suffix: "", digits: 1))
                BenchMetricRow(title: "Output", value: metric(.outputTokenCount, in: run, suffix: "tokens", digits: 0))
                BenchMetricRow(title: "Peak", value: peakMemory(in: run))
                BenchMetricRow(title: "Thermal", value: run.environment.thermalState)
                BenchMetricRow(title: "Low Power", value: run.environment.lowPowerMode ? "yes" : "no")
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History")
                .font(.headline)

            if viewModel.history.isEmpty {
                Text("No runs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.history, id: \.id) { run in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run.modelID)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(metric(.firstTokenLatencyMillis, in: run, suffix: "ms", digits: 0)) · \(metric(.tokensPerSecond, in: run, suffix: "tok/s", digits: 1))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(run.environment.thermalState)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func metric(
        _ metric: BenchMetric,
        in run: BenchRun,
        suffix: String,
        digits: Int
    ) -> String {
        guard let value = run.sampleValue(metric) else {
            return "-"
        }

        let formatted = String(format: "%.\(digits)f", value)
        return suffix.isEmpty ? formatted : "\(formatted) \(suffix)"
    }

    private func peakMemory(in run: BenchRun) -> String {
        guard let bytes = run.sampleValue(.peakMemoryBytes) else {
            return "-"
        }

        return "\(String(format: "%.1f", bytes / 1_048_576)) MB"
    }
}

private struct BenchMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
        }
    }
}
