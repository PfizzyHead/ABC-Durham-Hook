import SwiftUI
import UniformTypeIdentifiers
import SwingKinematicsEngine

struct ContentView: View {
    @StateObject private var viewModel = SwingAnalysisViewModel()
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Golf Launch Monitor")
                .font(.largeTitle.bold())

            Button {
                isImporting = true
            } label: {
                Label("Choose Capture…", systemImage: "video.badge.plus")
            }
            .controlSize(.large)
            .disabled(viewModel.isRunning)

            if viewModel.isRunning {
                ProgressView()
            }

            Text(viewModel.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let metrics = viewModel.metrics {
                MetricsView(metrics: metrics)
            }

            Spacer()
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 440)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.mpeg4Movie, .quickTimeMovie, .movie]
        ) { result in
            if case .success(let url) = result {
                viewModel.analyze(url: url)
            }
        }
    }
}

/// Read-only table of the derived swing metrics.
private struct MetricsView: View {
    let metrics: SwingMetrics

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("Ball speed", String(format: "%.1f mph", metrics.ballSpeed.milesPerHour))
            row("Launch angle", String(format: "%.1f°", metrics.launchAngle.degrees))
            row("Attack angle", String(format: "%.1f°", metrics.clubPath.attackAngleDegrees))
            row("Club path", String(format: "%.1f°", metrics.clubPath.horizontalAngleDegrees))
            Divider()
            row("Scale (mm/pixel)", String(format: "%.4f", metrics.calibration.mmPerPixel))
            row("Impact frame", "\(metrics.impactFrameIndex)")
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).gridColumnAlignment(.trailing)
        }
    }
}
