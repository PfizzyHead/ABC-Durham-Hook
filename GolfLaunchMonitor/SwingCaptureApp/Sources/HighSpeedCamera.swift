import AVFoundation

enum CameraError: LocalizedError {
    case noCamera
    case noHighSpeedFormat(Double)
    var errorDescription: String? {
        switch self {
        case .noCamera: return "No back camera available."
        case .noHighSpeedFormat(let fps):
            return "This device has no camera format supporting \(Int(fps)) FPS."
        }
    }
}

/// Configures and runs an `AVCaptureSession` locked to a high frame rate, and
/// fans video + audio sample buffers out to a delegate.
final class HighSpeedCamera: NSObject {

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "swingcapture.session")
    let sampleQueue = DispatchQueue(label: "swingcapture.samples")

    private(set) var frameRate: Double = 0
    private(set) var dimensions = CMVideoDimensions(width: 0, height: 0)

    weak var delegate: (AVCaptureVideoDataOutputSampleBufferDelegate
                        & AVCaptureAudioDataOutputSampleBufferDelegate)?

    /// Find the format that supports `targetFPS`, preferring 1080p, then the
    /// largest resolution available at that rate.
    static func bestFormat(for device: AVCaptureDevice, targetFPS: Double) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = -1
        for format in device.formats {
            let supportsRate = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= targetFPS }
            guard supportsRate else { continue }
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            // Prefer exactly 1080 tall; otherwise rank by pixel count.
            let score = (d.height == 1080) ? Int.max - 1 : Int(d.width) * Int(d.height)
            if score > bestScore { bestScore = score; best = format }
        }
        return best
    }

    func configure(targetFPS: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        sessionQueue.async {
            do { try self.configureLocked(targetFPS: targetFPS); completion(.success(())) }
            catch { completion(.failure(error)) }
        }
    }

    private func configureLocked(targetFPS: Double) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority // we set the device format manually

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noCamera
        }
        guard let format = Self.bestFormat(for: device, targetFPS: targetFPS) else {
            throw CameraError.noHighSpeedFormat(targetFPS)
        }

        try device.lockForConfiguration()
        device.activeFormat = format
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()

        frameRate = targetFPS
        dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

        let videoInput = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(videoInput) { session.addInput(videoInput) }

        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(delegate, queue: sampleQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(delegate, queue: sampleQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        // Side-on golf framing: keep the saved video upright in landscape.
        if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
    }

    func start() { sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stop()  { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }
}
