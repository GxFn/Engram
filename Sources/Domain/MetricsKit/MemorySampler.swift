import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct MemorySnapshot: Sendable, Hashable, Codable {
    public let capturedAt: Date
    public let physFootprintBytes: UInt64

    public init(capturedAt: Date, physFootprintBytes: UInt64) {
        self.capturedAt = capturedAt
        self.physFootprintBytes = physFootprintBytes
    }
}

public struct MemoryMeasurement<Value: Sendable>: Sendable {
    public let value: Value
    public let peak: MemorySnapshot

    public init(value: Value, peak: MemorySnapshot) {
        self.value = value
        self.peak = peak
    }
}

public enum MemorySamplerError: Error, Sendable, Equatable {
    case taskInfoFailed(Int32)
    case unsupportedPlatform
    case noSamples
}

public struct MemorySampler: Sendable {
    public typealias FootprintReader = @Sendable () throws -> UInt64

    public let intervalNanoseconds: UInt64
    private let readPhysFootprintBytes: FootprintReader
    private let now: @Sendable () -> Date

    public init(
        intervalNanoseconds: UInt64 = 500_000_000,
        readPhysFootprintBytes: @escaping FootprintReader = Self.currentPhysFootprintBytes,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.intervalNanoseconds = intervalNanoseconds
        self.readPhysFootprintBytes = readPhysFootprintBytes
        self.now = now
    }

    public func snapshot() throws -> MemorySnapshot {
        MemorySnapshot(
            capturedAt: now(),
            physFootprintBytes: try readPhysFootprintBytes()
        )
    }

    public func measure<Value: Sendable>(
        during operation: () async throws -> Value
    ) async throws -> MemoryMeasurement<Value> {
        let recorder = MemoryPeakRecorder()
        try await recorder.record(snapshot())

        let samplerTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                    try await recorder.record(snapshot())
                } catch {
                    return
                }
            }
        }

        do {
            let value = try await operation()
            samplerTask.cancel()
            try await recorder.record(snapshot())
            return try await MemoryMeasurement(value: value, peak: recorder.peak())
        } catch {
            samplerTask.cancel()
            try? await recorder.record(snapshot())
            throw error
        }
    }

    public static func currentPhysFootprintBytes() throws -> UInt64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            throw MemorySamplerError.taskInfoFailed(result)
        }

        return UInt64(info.phys_footprint)
        #else
        throw MemorySamplerError.unsupportedPlatform
        #endif
    }
}

private actor MemoryPeakRecorder {
    private var currentPeak: MemorySnapshot?

    func record(_ snapshot: MemorySnapshot) {
        guard let currentPeak else {
            self.currentPeak = snapshot
            return
        }

        if snapshot.physFootprintBytes > currentPeak.physFootprintBytes {
            self.currentPeak = snapshot
        }
    }

    func peak() throws -> MemorySnapshot {
        guard let currentPeak else {
            throw MemorySamplerError.noSamples
        }

        return currentPeak
    }
}
