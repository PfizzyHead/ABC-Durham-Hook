import Foundation
import SwingKinematicsEngine
#if canImport(CoreML)
import CoreML
#endif

/// Drives the analysis pipeline for the UI: decode the picked MP4, run the
/// engine, publish the resulting metrics.
@MainActor
final class SwingAnalysisViewModel: ObservableObject {

    @Published var status: String
    @Published var metrics: SwingMetrics?
    @Published var isRunning = false

    /// The detector used for analysis. `nil` means no model is available, in
    /// which case the app refuses to run rather than report misleading results.
    private let detector: SwingObjectDetector?

    /// Designated init — inject any detector (a real model, or a fixture in tests).
    init(detector: SwingObjectDetector?) {
        self.detector = detector
        self.status = detector == nil
            ? "No detection model bundled yet — add SwingDetector.mlpackage to the "
              + "app target to enable analysis (see MLModels/README.md)."
            : "Choose a 240 FPS capture (.mp4) to analyze."
    }

    /// Default init used by the app — auto-loads a CoreML model from the bundle.
    convenience init() {
        self.init(detector: try? Self.loadBundledDetector())
    }

    func analyze(url: URL) {
        guard let detector else {
            status = "Add SwingDetector.mlpackage to the app target to enable analysis "
                + "(see MLModels/README.md)."
            return
        }

        isRunning = true
        metrics = nil
        status = "Decoding & analyzing…"

        Task {
            // The file arrives as a security-scoped URL under the App Sandbox;
            // hold access for the duration of the read.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let provider = try await AVAssetReaderFrameProvider(url: url)
                let engine = SwingKinematicsEngine(detector: detector)
                metrics = try await engine.analyze(provider: provider)
                status = "Analysis complete."
            } catch {
                status = "Analysis failed: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }

    // MARK: - Model loading

    enum DetectorLoadError: LocalizedError {
        case modelNotBundled
        var errorDescription: String? {
            "No 'SwingDetector' CoreML model is bundled in the app target."
        }
    }

    /// Loads `SwingDetector` from the app bundle. Xcode compiles a bundled
    /// `SwingDetector.mlpackage` into `SwingDetector.mlmodelc` at build time.
    static func loadBundledDetector() throws -> SwingObjectDetector {
        #if canImport(CoreML)
        guard let url = Bundle.main.url(forResource: "SwingDetector", withExtension: "mlmodelc") else {
            throw DetectorLoadError.modelNotBundled
        }
        let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
        return try CoreMLObjectDetector(model: model)
        #else
        throw DetectorLoadError.modelNotBundled
        #endif
    }
}
