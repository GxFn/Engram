import EngineKit
import MLXEngine
import ModelStore
import Observation
import SwiftUI

@MainActor
@Observable
public final class AppDependencies {
    public let engines: [any LLMEngine]
    public var activeEngine: any LLMEngine
    public let modelStore: ModelStore
    public var activeModel: ModelIdentity

    public init(
        engines: [any LLMEngine] = [MLXEngine()],
        activeEngine: (any LLMEngine)? = nil,
        modelStore: ModelStore = ModelStore(),
        activeModel: ModelIdentity = DeviceCapability().recommendedModel
    ) {
        let resolvedEngines = engines.isEmpty ? [MLXEngine()] : engines

        self.engines = resolvedEngines
        self.activeEngine = activeEngine ?? resolvedEngines[0]
        self.modelStore = modelStore
        self.activeModel = activeModel
    }
}

private struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies? = nil
}

public extension EnvironmentValues {
    var deps: AppDependencies? {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
}
