import AVFoundation
import SwiftUI

/// Non-isolated sink for capture sample buffers. Kept separate from the
/// `@MainActor` coordinator so the high-frequency delegate callbacks never touch
/// main-actor state. Owns the recorder + impact detector, which are internally
/// thread-safe.
final class SampleRouter: NSObject,
                          AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {
    let recorder: ClipRecorder
    let impactDetector = ImpactDetector()

    init(dimensions: CMVideoDimensions) {
        recorder = ClipRecorder(configuration: .init(), dimensions: dimensions)
        super.init()
        impactDetector.onImpact = { [weak self] in self?.recorder.notifyImpact() }
    }

    func arm(threshold: Float) {
        impactDetector.threshold = threshold
        recorder.arm()
        impactDetector.enable()
    }
    func cancel() { recorder.cancel(); impactDetector.disable() }
    func triggerManually() { recorder.notifyImpact() }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            recorder.appendVideo(sampleBuffer)
        } else if output is AVCaptureAudioDataOutput {
            recorder.appendAudio(sampleBuffer)
            impactDetector.process(sampleBuffer)
        }
    }
}

/// Drives capture and exposes a small state machine to SwiftUI.
@MainActor
final class CaptureCoordinator: ObservableObject {

    enum State: Equatable {
        case configuring
        case ready
        case armed
        case saved(URL)
        case error(String)
    }

    @Published private(set) var state: State = .configuring
    @Published private(set) var savedClips: [URL] = []
    /// Audio-trigger sensitivity, exposed for field tuning.
    @Published var impactThreshold: Float = 0.35

    let camera = HighSpeedCamera()
    private var router: SampleRouter?
    private let targetFPS: Double

    init(targetFPS: Double = 240) {
        self.targetFPS = targetFPS
    }

    func start() {
        camera.configure(targetFPS: targetFPS) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    let router = SampleRouter(dimensions: self.camera.dimensions)
                    router.recorder.onClip = { [weak self] result in self?.handleClip(result) }
                    self.camera.delegate = router
                    self.router = router
                    self.camera.start()
                    self.state = .ready
                case .failure(let error):
                    self.state = .error(error.localizedDescription)
                }
            }
        }
    }

    func arm() {
        guard case .ready = state, let router else { return }
        router.arm(threshold: impactThreshold)
        state = .armed
    }

    /// Manual shutter for when audio triggering is unreliable (loud range, etc.).
    func triggerManually() {
        guard case .armed = state else { return }
        router?.triggerManually()
    }

    func cancelArm() {
        router?.cancel()
        if case .armed = state { state = .ready }
    }

    private func handleClip(_ result: Result<URL, Error>) {
        switch result {
        case .success(let tempURL):
            do {
                let saved = try persist(tempURL)
                savedClips.insert(saved, at: 0)
                state = .saved(saved)
            } catch {
                state = .error(error.localizedDescription)
            }
        case .failure(let error):
            state = .error(error.localizedDescription)
        }
    }

    /// Move a finished clip into Documents so it survives and is visible in the
    /// Files app (the app declares file sharing in Info.plist).
    private func persist(_ tempURL: URL) throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dest = docs.appendingPathComponent(tempURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }
}
