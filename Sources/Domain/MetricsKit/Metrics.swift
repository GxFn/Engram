import Foundation

public enum BenchMetric: String, Sendable, Hashable, Codable, CaseIterable {
    case firstTokenLatencyMillis
    case tokensPerSecond
    case outputTokenCount
    case peakMemoryBytes
}

/// One measured value inside a bench run (TTFT, tokens/s, peak RSS, …).
public struct BenchSample: Sendable, Hashable, Codable {
    public let metric: String
    public let value: Double
    public let unit: String

    public init(metric: String, value: Double, unit: String) {
        self.metric = metric
        self.value = value
        self.unit = unit
    }
}

/// Context that decides whether a run's numbers are trustworthy — bench
/// results recorded under thermal throttling or Low Power Mode are flagged,
/// never silently mixed into the README table.
public struct BenchEnvironment: Sendable, Hashable, Codable {
    public let deviceModel: String
    public let thermalState: String
    public let lowPowerMode: Bool

    public init(deviceModel: String, thermalState: String, lowPowerMode: Bool) {
        self.deviceModel = deviceModel
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
    }
}

public struct BenchRun: Sendable, Hashable, Codable {
    public let id: String
    public let startedAt: Date
    public let engineID: String
    public let modelID: String
    public let environment: BenchEnvironment
    public let samples: [BenchSample]

    public init(
        id: String,
        startedAt: Date,
        engineID: String,
        modelID: String,
        environment: BenchEnvironment,
        samples: [BenchSample]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.engineID = engineID
        self.modelID = modelID
        self.environment = environment
        self.samples = samples
    }
}

public extension BenchRun {
    func sampleValue(_ metric: BenchMetric) -> Double? {
        samples.first { $0.metric == metric.rawValue }?.value
    }
}

public protocol MetricsCollecting: Sendable {
    func record(_ sample: BenchSample)
}
