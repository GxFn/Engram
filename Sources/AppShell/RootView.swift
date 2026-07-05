import AskFeature
import BenchFeature
import MemoryFeature
import SettingsFeature
import SwiftUI

/// App shell: three-tab layout per the requirement design (Memory / Ask /
/// Bench; Settings is a page, not a tab). Dependency injection of engines and
/// stores happens here and only here — features never see Infrastructure.
public struct RootView: View {
    public init() {}

    public var body: some View {
        TabView {
            NavigationStack { MemoryView() }
                .tabItem { Label("Memory", systemImage: "tray.full") }

            NavigationStack { AskView() }
                .tabItem { Label("Ask", systemImage: "questionmark.bubble") }

            NavigationStack { BenchView() }
                .tabItem { Label("Bench", systemImage: "gauge.with.dots.needle.67percent") }
        }
    }
}
