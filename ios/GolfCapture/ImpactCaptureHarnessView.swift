import Foundation
import SwiftUI
import AVKit

@MainActor
struct ImpactCaptureHarnessView: View {
    @ObservedObject var bridge: ImpactCaptureBridge

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                stateBanner
                actionButtons
                thresholdControls
                videoPlayback
                debugConsole
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: bridge.lastExportedVideoURL) { newURL in
            configurePlayer(for: newURL)
        }
        .onAppear {
            configurePlayer(for: bridge.lastExportedVideoURL)
        }
    }

    private var stateBanner: some View {
        Text(stateDisplay.title)
            .font(.system(size: 48, weight: .black, design: .monospaced))
            .minimumScaleFactor(0.55)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 112)
            .foregroundStyle(stateDisplay.foreground)
            .background(stateDisplay.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.75), lineWidth: 3)
            }
            .accessibilityLabel("Capture state \(stateDisplay.title)")
    }

    private var actionButtons: some View {
        HStack(spacing: 14) {
            Button {
                bridge.startListening()
            } label: {
                Label("Start Listening", systemImage: "dot.radiowaves.left.and.right")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)

            Button(role: .destructive) {
                bridge.stopListening()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private var thresholdControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Thresholds")
                .font(.title2.weight(.black))
                .foregroundStyle(.white)

            ThresholdSlider(
                title: "Attack Ratio",
                value: floatBinding(\.attackRatio),
                range: 1...12,
                step: 0.1,
                format: "%.1f"
            )

            ThresholdSlider(
                title: "Brightness Ratio",
                value: floatBinding(\.brightnessRatio),
                range: 0...1,
                step: 0.01,
                format: "%.2f"
            )

            ThresholdSlider(
                title: "High Band Hz",
                value: floatBinding(\.highBandHz),
                range: 500...12_000,
                step: 50,
                format: "%.0f Hz"
            )
        }
        .padding(16)
        .background(Color(.sRGB, white: 0.08, opacity: 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var videoPlayback: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last Export")
                .font(.title2.weight(.black))
                .foregroundStyle(.white)

            if let player {
                VideoPlayer(player: player)
                    .frame(minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.cyan.opacity(0.75), lineWidth: 2)
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 54, weight: .bold))
                    Text("NO EXPORTED VIDEO")
                        .font(.system(.title2, design: .monospaced).weight(.black))
                }
                .foregroundStyle(.white.opacity(0.86))
                .frame(maxWidth: .infinity, minHeight: 260)
                .background(Color(.sRGB, white: 0.06, opacity: 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                }
            }
        }
    }

    private var debugConsole: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Debug Console")
                .font(.title2.weight(.black))
                .foregroundStyle(.white)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(bridge.debugLogs.enumerated()), id: \.offset) { index, entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .frame(minHeight: 220, maxHeight: 340)
                .background(Color.black)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.green.opacity(0.7), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onChange(of: bridge.debugLogs.count) { count in
                    guard count > 0 else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var stateDisplay: (title: String, background: Color, foreground: Color) {
        switch bridge.currentState {
        case .idle:
            return ("IDLE", .gray, .white)
        case .listening:
            return ("LISTENING", .yellow, .black)
        case .recording:
            return ("RECORDING", .red, .white)
        case .exporting:
            return ("EXPORTING", .cyan, .black)
        }
    }

    private func floatBinding(_ keyPath: ReferenceWritableKeyPath<ImpactCaptureBridge, Float>) -> Binding<Double> {
        Binding<Double> {
            Double(bridge[keyPath: keyPath])
        } set: { newValue in
            bridge[keyPath: keyPath] = Float(newValue)
        }
    }

    private func configurePlayer(for url: URL?) {
        player?.pause()
        player = nil
        looper = nil

        guard let url else { return }

        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)

        looper = playerLooper
        player = queuePlayer
        queuePlayer.play()
    }
}

private struct ThresholdSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: format, value))
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .foregroundStyle(.yellow)
            }

            Slider(value: $value, in: range, step: step)
                .tint(.yellow)
        }
    }
}
