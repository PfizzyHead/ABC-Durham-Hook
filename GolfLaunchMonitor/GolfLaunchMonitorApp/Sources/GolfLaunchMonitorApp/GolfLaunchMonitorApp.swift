import SwiftUI

/// SwiftUI entry point for the Golf Launch Monitor desktop app. The app is a thin
/// shell over `SwingKinematicsEngine`: it lets you pick a Phase-1 capture and
/// renders the kinematic metrics the engine derives.
@main
struct GolfLaunchMonitorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 480, height: 460)
    }
}
