import EngineKit
import Foundation

public struct DeviceCapability: Sendable, Equatable {
    public static let gibibyte: Int64 = 1_024 * 1_024 * 1_024
    public static let qwen3FourBRecommendedMemoryBytes: Int64 = 7 * gibibyte

    public let physicalMemoryBytes: Int64
    public let safetyFactor: Double

    public init(
        physicalMemoryBytes: Int64 = Int64(clamping: ProcessInfo.processInfo.physicalMemory),
        safetyFactor: Double = 1.4
    ) {
        self.physicalMemoryBytes = max(0, physicalMemoryBytes)
        self.safetyFactor = safetyFactor
    }

    public var recommendedModel: ModelIdentity {
        if physicalMemoryBytes >= Self.qwen3FourBRecommendedMemoryBytes {
            return ModelCatalog.qwen3_4B_4bit
        }

        return ModelCatalog.qwen3_1_7B_4bit
    }

    public func canRun(_ model: ModelIdentity) -> Bool {
        requiredMemoryBytes(for: model) <= physicalMemoryBytes
    }

    public func requiredMemoryBytes(for model: ModelIdentity) -> Int64 {
        let estimatedBytes = max(0, model.estimatedMemoryBytes)
        let required = (Double(estimatedBytes) * safetyFactor).rounded(.up)

        if required >= Double(Int64.max) {
            return Int64.max
        }

        return Int64(required)
    }
}
