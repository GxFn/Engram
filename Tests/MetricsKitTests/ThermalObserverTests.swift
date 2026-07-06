import MetricsKit
import Testing

@Test func thermalObserverUsesInjectedSnapshotProvider() {
    let observer = ThermalObserver {
        ThermalSnapshot(thermalState: .serious, lowPowerMode: true)
    }

    let snapshot = observer.snapshot()
    let environment = snapshot.environment(deviceModel: "TestDevice")

    #expect(snapshot.thermalState == .serious)
    #expect(snapshot.lowPowerMode == true)
    #expect(environment.deviceModel == "TestDevice")
    #expect(environment.thermalState == "serious")
    #expect(environment.lowPowerMode == true)
}
