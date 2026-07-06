import Foundation

public enum BenchThermalState: String, Sendable, Hashable, Codable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public struct ThermalSnapshot: Sendable, Hashable, Codable {
    public let thermalState: BenchThermalState
    public let lowPowerMode: Bool

    public init(thermalState: BenchThermalState, lowPowerMode: Bool) {
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
    }

    public func environment(deviceModel: String) -> BenchEnvironment {
        BenchEnvironment(
            deviceModel: deviceModel,
            thermalState: thermalState.rawValue,
            lowPowerMode: lowPowerMode
        )
    }
}

public struct ThermalObserver: Sendable {
    public typealias SnapshotProvider = @Sendable () -> ThermalSnapshot

    private let snapshotProvider: SnapshotProvider

    public init(snapshotProvider: @escaping SnapshotProvider = Self.currentSnapshot) {
        self.snapshotProvider = snapshotProvider
    }

    public func snapshot() -> ThermalSnapshot {
        snapshotProvider()
    }

    public static func currentSnapshot() -> ThermalSnapshot {
        ThermalSnapshot(
            thermalState: BenchThermalState(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
}

private extension BenchThermalState {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .unknown
        }
    }
}
