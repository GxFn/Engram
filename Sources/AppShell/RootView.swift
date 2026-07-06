import AskFeature
import BenchFeature
import MemoryFeature
import Persistence
import SettingsFeature
import SwiftData
import SwiftUI

/// App shell: three-tab layout per the requirement design (Memory / Ask /
/// Bench; Settings is a page, not a tab). Dependency injection of engines and
/// stores happens here and only here — features never see Infrastructure.
public struct RootView: View {
    @State private var dependencies: AppDependencies
    private let modelContainer: ModelContainer?

    @MainActor
    public init(
        dependencies: AppDependencies? = nil,
        modelContainer: ModelContainer? = try? PersistenceStack.makeContainer()
    ) {
        _dependencies = State(initialValue: dependencies ?? AppDependencies(modelContainer: modelContainer))
        self.modelContainer = modelContainer
    }

    public var body: some View {
        let content = RootContent()
            .environment(\.deps, Optional(dependencies))

        if let modelContainer {
            content.modelContainer(modelContainer)
        } else {
            content
        }
    }
}

private struct RootContent: View {
    private enum RootTab: Hashable {
        case memory
        case ask
        case bench
    }

    @Environment(\.deps) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarded") private var onboarded = false
    @State private var selectedTab: RootTab = .memory
    @State private var memoryNavigationTarget: MemoryNavigationTarget?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                if let dependencies {
                    MemoryView(
                        viewModel: dependencies.makeMemoryViewModel(),
                        navigationTarget: $memoryNavigationTarget
                    )
                        .toolbar { settingsToolbar }
                } else {
                    ContentUnavailableView("Memory", systemImage: "tray.full")
                        .toolbar { settingsToolbar }
                }
            }
                .tabItem { Label("Memory", systemImage: "tray.full") }
                .tag(RootTab.memory)

            NavigationStack {
                if let dependencies {
                    AskView(viewModel: dependencies.makeAskViewModel()) { citation in
                        memoryNavigationTarget = AppDependencies.memoryNavigationTarget(for: citation)
                        selectedTab = .memory
                    }
                    .id(consumerIdentity(for: dependencies))
                    .toolbar { settingsToolbar }
                }
            }
                .tabItem { Label("Ask", systemImage: "questionmark.bubble") }
                .tag(RootTab.ask)

            NavigationStack {
                if let dependencies {
                    BenchView(viewModel: dependencies.makeBenchViewModel())
                    .id(consumerIdentity(for: dependencies))
                    .toolbar { settingsToolbar }
                }
            }
                .tabItem { Label("Bench", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(RootTab.bench)
        }
        .sheet(isPresented: onboardingPresented) {
            if let dependencies {
                OnboardingView(
                    viewModel: dependencies.makeSettingsViewModel(),
                    complete: { onboarded = true }
                )
            }
        }
        .task {
            await dependencies?.digestPendingClips()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await dependencies?.digestPendingClips() }
            case .background:
                dependencies?.scheduleClipDigest()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            NavigationLink {
                settingsDestination
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }

    @ViewBuilder
    private var settingsDestination: some View {
        if let dependencies {
            SettingsView(viewModel: dependencies.makeSettingsViewModel())
        } else {
            ContentUnavailableView("Settings", systemImage: "gearshape")
        }
    }

    private var onboardingPresented: Binding<Bool> {
        Binding(
            get: { !onboarded && dependencies != nil },
            set: { presented in
                if !presented {
                    onboarded = true
                }
            }
        )
    }

    private func consumerIdentity(for dependencies: AppDependencies) -> String {
        [
            dependencies.activeEngine.descriptor.id,
            dependencies.activeModel.id,
            String(format: "%.3f", dependencies.generationConfig.temperature),
            String(format: "%.3f", dependencies.generationConfig.topP),
            "\(dependencies.generationConfig.maxTokens)",
        ].joined(separator: "|")
    }
}
