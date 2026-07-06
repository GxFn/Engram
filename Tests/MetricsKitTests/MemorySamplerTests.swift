import Foundation
import MetricsKit
import Testing

@Test func memorySamplerUsesInjectedPhysFootprintReader() throws {
    let sequence = FootprintSequence([123, 456])
    let sampler = MemorySampler(
        intervalNanoseconds: 1,
        readPhysFootprintBytes: sequence.next,
        now: { Date(timeIntervalSince1970: 10) }
    )

    let snapshot = try sampler.snapshot()

    #expect(snapshot.physFootprintBytes == 123)
    #expect(snapshot.capturedAt == Date(timeIntervalSince1970: 10))
}

@Test func memorySamplerMeasuresPeakDuringOperation() async throws {
    let sequence = FootprintSequence([100, 300, 200])
    let sampler = MemorySampler(
        intervalNanoseconds: 1_000_000,
        readPhysFootprintBytes: sequence.next,
        now: Date.init
    )

    let measurement = try await sampler.measure {
        try await Task.sleep(nanoseconds: 2_000_000)
        return "done"
    }

    #expect(measurement.value == "done")
    #expect(measurement.peak.physFootprintBytes >= 300)
}

private final class FootprintSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    private var last: UInt64

    init(_ values: [UInt64]) {
        self.values = values
        self.last = values.last ?? 0
    }

    func next() throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        guard !values.isEmpty else {
            return last
        }

        last = values.removeFirst()
        return last
    }
}
