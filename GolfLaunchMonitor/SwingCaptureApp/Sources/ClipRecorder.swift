import AVFoundation

enum RecorderError: LocalizedError {
    case timedOutWaitingForImpact
    case writeFailed(Error?)
    case exportFailed(Error?)
    var errorDescription: String? {
        switch self {
        case .timedOutWaitingForImpact: return "No impact detected — re-arm and try again."
        case .writeFailed(let e): return "Recording failed: \(e?.localizedDescription ?? "unknown")."
        case .exportFailed(let e): return "Trimming failed: \(e?.localizedDescription ?? "unknown")."
        }
    }
}

/// Captures the Phase-1 window (pre-impact + post-impact) without holding raw
/// frames in memory.
///
/// Strategy: while *armed*, continuously encode incoming frames to a temporary
/// H.264 file on disk (cheap). On `notifyImpact()` it marks the trigger time;
/// once `postRoll` seconds have elapsed it stops and uses a passthrough export to
/// trim the file to exactly `[impact − preRoll, impact + postRoll]` — preserving
/// the native 240 FPS. Buffering compressed video on disk avoids the multi-GB
/// RAM cost of keeping a second of raw 1080p frames.
final class ClipRecorder {

    struct Configuration {
        var preRoll: Double = 1.0
        var postRoll: Double = 1.5
        /// Max seconds to stay armed before giving up (bounds the temp file).
        var maxArmedSeconds: Double = 20.0
    }

    /// Called on the main queue when a clip finalizes or the attempt fails.
    var onClip: ((Result<URL, Error>) -> Void)?

    private let config: Configuration
    private let dimensions: CMVideoDimensions
    private let queue = DispatchQueue(label: "swingcapture.recorder")

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStart: CMTime = .invalid
    private var triggerPTS: CMTime = .invalid
    private var armed = false
    private var finishing = false
    private var tempURL: URL?

    init(configuration: Configuration, dimensions: CMVideoDimensions) {
        self.config = configuration
        self.dimensions = dimensions
    }

    // MARK: Public API

    func arm() { queue.async { self.armLocked() } }

    func notifyImpact() {
        queue.async {
            guard self.armed, !self.finishing, CMTIME_IS_INVALID(self.triggerPTS) else { return }
            // Trigger is stamped on the next appended frame's PTS for precision.
            self.triggerPTS = .zero // sentinel: "stamp on next frame"
        }
    }

    func appendVideo(_ sb: CMSampleBuffer) { queue.async { self.handleVideo(sb) } }
    func appendAudio(_ sb: CMSampleBuffer) { queue.async { self.handleAudio(sb) } }

    func cancel() { queue.async { self.teardown(deleteTemp: true) } }

    // MARK: Internals

    private func armLocked() {
        teardown(deleteTemp: true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swing-raw-\(UUID().uuidString).mp4")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height)
        ])
        videoInput.expectsMediaDataInRealTime = true
        if w.canAdd(videoInput) { w.add(videoInput) }

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000
        ])
        audioInput.expectsMediaDataInRealTime = true
        if w.canAdd(audioInput) { w.add(audioInput) }

        writer = w
        self.videoInput = videoInput
        self.audioInput = audioInput
        tempURL = url
        sessionStart = .invalid
        triggerPTS = .invalid
        finishing = false
        armed = true
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard armed, let writer, let videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)

        if CMTIME_IS_INVALID(sessionStart) {
            sessionStart = pts
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
        }

        // Stamp the impact time on the first frame after the trigger sentinel.
        if CMTimeCompare(triggerPTS, .zero) == 0 {
            triggerPTS = pts
        }

        if videoInput.isReadyForMoreMediaData { videoInput.append(sb) }

        // Stop conditions.
        if CMTIME_IS_VALID(triggerPTS), CMTimeCompare(triggerPTS, .zero) > 0 {
            let deadline = CMTimeAdd(triggerPTS, CMTime(seconds: config.postRoll, preferredTimescale: 600))
            if CMTimeCompare(pts, deadline) >= 0 { finalize() }
        } else if CMTimeGetSeconds(CMTimeSubtract(pts, sessionStart)) > config.maxArmedSeconds {
            fail(.timedOutWaitingForImpact)
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard armed, !finishing, let audioInput, CMTIME_IS_VALID(sessionStart) else { return }
        if audioInput.isReadyForMoreMediaData { audioInput.append(sb) }
    }

    private func finalize() {
        guard armed, !finishing, let writer, CMTIME_IS_VALID(triggerPTS) else { return }
        finishing = true
        armed = false
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        let rawURL = writer.outputURL
        // Window is relative to the asset start (sessionStart maps to asset t=0).
        let windowStart = max(0, CMTimeGetSeconds(CMTimeSubtract(triggerPTS, sessionStart)) - config.preRoll)
        let duration = config.preRoll + config.postRoll

        writer.finishWriting { [weak self] in
            guard let self else { return }
            if writer.status != .completed {
                self.deliver(.failure(RecorderError.writeFailed(writer.error)))
                return
            }
            self.trim(rawURL: rawURL, start: windowStart, duration: duration)
        }
    }

    private func trim(rawURL: URL, start: Double, duration: Double) {
        let asset = AVURLAsset(url: rawURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            deliver(.failure(RecorderError.exportFailed(nil))); return
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swing-\(UUID().uuidString).mp4")
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        export.exportAsynchronously { [weak self] in
            if export.status == .completed {
                self?.deliver(.success(outURL))
            } else {
                self?.deliver(.failure(RecorderError.exportFailed(export.error)))
            }
            try? FileManager.default.removeItem(at: rawURL)
        }
    }

    private func fail(_ error: RecorderError) {
        guard !finishing else { return }
        finishing = true
        armed = false
        writer?.cancelWriting()
        deliver(.failure(error))
    }

    private func deliver(_ result: Result<URL, Error>) {
        queue.async { self.teardown(deleteTemp: false) }
        DispatchQueue.main.async { self.onClip?(result) }
    }

    private func teardown(deleteTemp: Bool) {
        if deleteTemp, let t = tempURL { try? FileManager.default.removeItem(at: t) }
        writer = nil; videoInput = nil; audioInput = nil
        sessionStart = .invalid; triggerPTS = .invalid
        armed = false; finishing = false; tempURL = nil
    }
}
