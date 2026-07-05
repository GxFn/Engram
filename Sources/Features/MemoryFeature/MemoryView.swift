import ClipCore
import SwiftUI

/// Memory surface — the clip timeline with per-clip digestion state badges.
/// Opening this screen is the guaranteed digestion trigger (foreground drain).
public struct MemoryView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            "Your clips live here",
            systemImage: "tray.full",
            description: Text("Clip pipeline lands in M2.")
        )
        .navigationTitle("Memory")
    }
}
