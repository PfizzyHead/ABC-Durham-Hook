import Foundation
import SwingKinematicsEngine

/// Drives the analysis pipeline for the UI: decode the picked MP4, run the
/// engine, publish the resulting metrics.
@MainActor
final class SwingAnalysisViewModel: ObservableObject {

    @Published var status: String = "Choose a 240 FPS capture (.mp4) to analyze."
    @Published var metrics: SwingMetrics?
    @Published var isRunning = false

    /// Factory for the object detector. It is **nil until you bundle a trained
    /// model**: the engine cannot find impact (or any object) without one, so the
    /// app deliberately refuses to run rather than report a misleading failure.
    ///
    /// Once you have a YOLOv8-nano exported to CoreML, set this, e.g.:
    ///
    ///     vm.makeDetector = {
    ///         let model = try MLModel(contentsOf: Bundle.main.url(
    ///             forResource: "SwingDetector", withExtension: "mlmodelc")!)
    ///         return try CoreMLObjectDetector(model: model)
    ///     }
    var makeDetector: (() throws -> SwingObjectDetector)?

    func analyze(url: URL) {
        guard let makeDetector else {
            status = """
            No detection model bundled yet. Add a YOLOv8-nano CoreML model and \
            wire it into SwingAnalysisViewModel.makeDetector to enable analysis.
            """
            return
        }

        isRunning = true
        metrics = nil
        status = "Decoding & analyzing…"

        Task {
            // The file was chosen via the system picker, so it arrives as a
            // security-scoped URL under the App Sandbox; hold access for the read.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let provider = try await AVAssetReaderFrameProvider(url: url)
                let engine = SwingKinematicsEngine(detector: try makeDetector())
                let result = try await engine.analyze(provider: provider)
                metrics = result
                status = "Analysis complete."
            } catch {
                status = "Analysis failed: \(error)"
            }
            isRunning = false
        }
    }
}
