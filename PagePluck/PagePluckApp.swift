import SwiftUI

/// App entry point. The whole UI is a single browsing screen (`BrowserView`)
/// that lets you navigate to a page, log in if needed, scan it for media,
/// pick what to keep, and save it to Photos or Files.
@main
struct PagePluckApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
