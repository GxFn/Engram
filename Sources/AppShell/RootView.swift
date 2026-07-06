import AskFeature
import BenchFeature
import MemoryFeature
import SettingsFeature
import SwiftUI

/// App shell: three-tab layout per the requirement design (Memory / Ask /
/// Bench; Settings is a page, not a tab). Dependency injection of engines and
/// stores happens here and only here — features never see Infrastructure.
public struct RootView: View {
    @State private var dependencies: AppDependencies

    @MainActor
    public init(dependencies: AppDependencies = AppDependencies()) {
        _dependencies = State(initialValue: dependencies)
    }

    public var body: some View {
        RootContent()
            .environment(\.deps, Optional(dependencies))
    }
}

private struct RootContent: View {
    @Environment(\.deps) private var dependencies

    var body: some View {
        TabView {
            NavigationStack { MemoryView() }
                .tabItem { Label("Memory", systemImage: "tray.full") }

            NavigationStack {
                if let dependencies {
                    AskView(
                        engine: dependencies.activeEngine,
                        model: dependencies.activeModel
                    )
                }
            }
                .tabItem { Label("Ask", systemImage: "questionmark.bubble") }

            NavigationStack { BenchView() }
                .tabItem { Label("Bench", systemImage: "gauge.with.dots.needle.67percent") }
        }
    }
}
