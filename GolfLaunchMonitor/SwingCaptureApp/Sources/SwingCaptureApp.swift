import SwiftUI

/// Entry point for the iOS swing-capture app. This is the data-collection /
/// Phase-1 tool: it records a 240 FPS clip centered on impact and saves the raw
/// MP4 for analysis (and, later, for building the training set).
@main
struct SwingCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
