import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var coordinator = CaptureCoordinator()
    @State private var shareURL: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreviewView(session: coordinator.camera.session)
                .ignoresSafeArea()
            overlay
        }
        .onAppear { coordinator.start() }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
    }

    private var overlay: some View {
        VStack {
            HStack {
                statusPill
                Spacer()
                if !coordinator.savedClips.isEmpty {
                    Button {
                        shareURL = coordinator.savedClips.first
                    } label: {
                        Label("\(coordinator.savedClips.count)", systemImage: "square.and.arrow.up")
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
            .padding()

            Spacer()

            controls
                .padding(.bottom, 28)
        }
        .foregroundStyle(.white)
    }

    private var statusPill: some View {
        Text(statusText)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(statusColor.opacity(0.85), in: Capsule())
    }

    @ViewBuilder
    private var controls: some View {
        switch coordinator.state {
        case .ready, .saved:
            Button(action: coordinator.arm) {
                Text("Arm").font(.title2.bold())
                    .frame(width: 160, height: 56)
                    .background(.green, in: Capsule())
            }
        case .armed:
            VStack(spacing: 16) {
                Text("Take your swing — auto-triggers on impact")
                    .font(.footnote)
                HStack(spacing: 20) {
                    Button("Cancel", action: coordinator.cancelArm)
                        .frame(width: 120, height: 50)
                        .background(.gray, in: Capsule())
                    Button("Manual", action: coordinator.triggerManually)
                        .frame(width: 120, height: 50)
                        .background(.orange, in: Capsule())
                }
                sensitivity
            }
        case .configuring:
            ProgressView().tint(.white)
        case .error(let message):
            Text(message).font(.footnote).padding()
                .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var sensitivity: some View {
        VStack(spacing: 4) {
            Text("Impact sensitivity").font(.caption2)
            Slider(value: $coordinator.impactThreshold, in: 0.1...0.9)
                .frame(width: 220)
        }
    }

    private var statusText: String {
        switch coordinator.state {
        case .configuring: return "Starting camera…"
        case .ready: return "Ready • \(Int(coordinator.camera.frameRate)) FPS"
        case .armed: return "Armed"
        case .saved: return "Saved ✓"
        case .error: return "Error"
        }
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .armed: return .green
        case .error: return .red
        default: return .black
        }
    }
}

/// UIKit share sheet bridge for exporting clips out of the app.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: Identifiable { public var id: String { absoluteString } }
