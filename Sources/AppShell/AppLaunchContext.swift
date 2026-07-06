import Persistence
import SwiftData

@MainActor
public struct AppLaunchContext {
    public let dependencies: AppDependencies
    public let rootView: RootView

    public init(
        dependencies: AppDependencies,
        modelContainer: ModelContainer?
    ) {
        dependencies.configureClipDigestTriggers()
        self.dependencies = dependencies
        self.rootView = RootView(dependencies: dependencies, modelContainer: modelContainer)
    }

    public static func live() -> AppLaunchContext {
        let modelContainer = try? PersistenceStack.makeContainer()
        let dependencies = AppDependencies(modelContainer: modelContainer)
        return AppLaunchContext(dependencies: dependencies, modelContainer: modelContainer)
    }
}
