import EngineKit
import SwiftUI

/// Settings — model management (download/delete/storage/device recommendation),
/// engine selection, retrieval and generation parameters. First-launch
/// onboarding (device check → model recommendation → download) also lives here.
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            "Settings",
            systemImage: "gearshape",
            description: Text("Model manager lands in M1.")
        )
        .navigationTitle("Settings")
    }
}
