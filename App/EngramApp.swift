import SwiftUI
import AppShell

// App entry point. This file belongs to the Xcode app target, not the SPM
// package — see README "Building the app" for the one-time target setup.
@main
struct EngramApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
