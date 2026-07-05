import EngineKit
import MetricsKit
import SwiftUI

/// Bench surface — fixed prompt suite, engine/model pickers, result history,
/// Markdown export for the README table. M3 adds the side-by-side dual-engine
/// comparison used in live demos.
public struct BenchView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            "Benchmarks",
            systemImage: "gauge.with.dots.needle.67percent",
            description: Text("Minimal runner lands in M1; TTFT, tokens/s and peak memory are measured on device, never fabricated.")
        )
        .navigationTitle("Bench")
    }
}
