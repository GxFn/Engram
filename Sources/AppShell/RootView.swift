import AskFeature
import BenchFeature
import MemoryFeature
import Persistence
import RAGCore
import SettingsFeature
import SwiftData
import SwiftUI

/// App shell: dual-function three-tab layout (剪藏 clips / 拆解 studio / 问答 ask);
/// Settings (with Bench) is a page reached from the toolbar. The 剪藏 and 拆解 tabs
/// render the same shared MemoryViewModel filtered by content kind. Dependency
/// injection happens here and only here — features never see Infrastructure.
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
        case clips
        case studio
        case ask
    }

    @Environment(\.deps) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarded") private var onboarded = false
    @State private var selectedTab: RootTab = .clips
    @State private var memoryNavigationTarget: MemoryNavigationTarget?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                if let dependencies {
                    MemoryView(
                        kind: .clips,
                        viewModel: dependencies.makeMemoryViewModel(),
                        navigationTarget: $memoryNavigationTarget
                    )
                        .id(dependencies.aiRoutingSignature)
                        .toolbar { settingsToolbar }
                } else {
                    ContentUnavailableView("剪藏", systemImage: "tray.full")
                        .toolbar { settingsToolbar }
                }
            }
                .tabItem { Label("剪藏", systemImage: "tray.full") }
                .tag(RootTab.clips)

            NavigationStack {
                if let dependencies {
                    MemoryView(
                        kind: .studio,
                        viewModel: dependencies.makeMemoryViewModel(),
                        navigationTarget: $memoryNavigationTarget
                    )
                        .id(dependencies.aiRoutingSignature)
                        .toolbar { settingsToolbar }
                } else {
                    ContentUnavailableView("拆解", systemImage: "film.stack")
                        .toolbar { settingsToolbar }
                }
            }
                .tabItem { Label("拆解", systemImage: "film.stack") }
                .tag(RootTab.studio)

            NavigationStack {
                if let dependencies {
                    AskView(viewModel: dependencies.makeAskViewModel()) { citation in
                        routeCitation(citation, dependencies: dependencies)
                    }
                    .id(consumerIdentity(for: dependencies))
                    .toolbar { settingsToolbar }
                }
            }
                .tabItem { Label("问答", systemImage: "questionmark.bubble") }
                .tag(RootTab.ask)
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
                // Re-apply any 云端/本地 change made while backgrounded (e.g. editing credentials).
                dependencies?.reloadAIRouting()
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

    /// Routes an Ask citation to the tab that owns its source, then pushes its detail.
    private func routeCitation(_ citation: CitationRef, dependencies: AppDependencies) {
        let isVideo = dependencies.makeMemoryViewModel().items
            .first { $0.id == citation.clipID }?
            .isVideoBreakdown ?? false
        selectedTab = isVideo ? .studio : .clips
        memoryNavigationTarget = AppDependencies.memoryNavigationTarget(for: citation)
    }

    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            NavigationLink {
                settingsDestination
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("设置")
        }
    }

    @ViewBuilder
    private var settingsDestination: some View {
        if let dependencies {
            SettingsView(viewModel: dependencies.makeSettingsViewModel())
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        NavigationLink {
                            BenchView(viewModel: dependencies.makeBenchViewModel())
                                .navigationTitle("跑分")
                        } label: {
                            Label("跑分", systemImage: "gauge.with.dots.needle.67percent")
                        }
                    }
                }
        } else {
            ContentUnavailableView("设置", systemImage: "gearshape")
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
