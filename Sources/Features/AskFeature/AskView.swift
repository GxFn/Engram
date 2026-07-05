import EngineKit
import SwiftUI

/// Ask surface — "问出来". During M1 this doubles as the engine debugging
/// console: streaming tokens, engine badge, per-message metrics on long press.
/// Citations attach in M2 once retrieval exists.
public struct AskView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            "Ask your clips",
            systemImage: "questionmark.bubble",
            description: Text("Engine wiring lands in M1.")
        )
        .navigationTitle("Ask")
    }
}
