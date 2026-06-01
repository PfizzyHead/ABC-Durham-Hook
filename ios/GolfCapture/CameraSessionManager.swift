//
//  CameraSessionManager.swift
//  GolfCapture — Phase 1: High-Speed Data Capture Engine
//
//  Owns the AVCaptureSession and locks the camera into the exact regime a launch
//  monitor needs: 1080p @ 240 FPS, manual ≤1/2000 s shutter (no rolling-shutter
//  smear on a 100+ mph club), and focus pinned at infinity.
//
//  ──────────────────────────────────────────────────────────────────────────
//  ARCHITECTURE
//  ──────────────────────────────────────────────────────────────────────────
//      AVCaptureDevice ──▶ AVCaptureVideoDataOutput
//                              │ (sampleBufferQueue, serial)
//                              ▼
//                          VideoEncoder ──▶ FrameRingBuffer (3 s pre-roll)
//
//  The owner (ImpactCaptureCoordinator) wires `onEncodedFrame` from the encoder
//  into the ring buffer and listens to the audio trigger.
//
//  ──────────────────────────────────────────────────────────────────────────
//  MEMORY FOOTPRINT AT 240 FPS
//  ──────────────────────────────────────────────────────────────────────────
//  • `alwaysDiscardsLateVideoFrames = true`: if the encoder ever falls behind,
//    AVFoundation drops frames instead of queuing them. This caps in-flight
//    pixel-buffer memory and prevents an unbounded backlog (the classic
//    high-FPS OOM).
//  • Each delegate callback hands the CVPixelBuffer straight to the encoder and
//    returns. We never copy it and never retain it past the call, so the
//    capture pixel-buffer pool recycles its (small, fixed) set of buffers and
//    total live pixel memory stays bounded — only the tiny compressed frames
//    accumulate, and those live in the bounded ring buffer.
//

import Foundation
import AVFoundation

final class CameraSessionManager: NSObject {

    /// Forwarded from the encoder; the coordinator pushes these into the ring.
    var onEncodedFrame: ((EncodedFrame) -> Void)?

    /// Surfaces session lifecycle / health events so the UI can react (show an
    /// overlay on interruption, warn on thermal pressure, recover on error).
    var onStatusChange: ((Status) -> Void)?

    /// Coarse health/lifecycle states the capture session can report.
    enum Status {
        case interrupted(reason: AVCaptureSession.InterruptionReason?)
        case interruptionEnded
        case runtimeError(Error)
        case thermalStateChanged(ProcessInfo.ThermalState)
    }

    let session = AVCaptureSession()
    private let sampleBufferQueue = DispatchQueue(label: "golf.capture.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var encoder: VideoEncoder!          // sized to the format we actually get
    private var device: AVCaptureDevice?

    private let targetFPS: Double = 240
    /// Resolution preference, best → acceptable. Not every device exposes a
    /// native 1080p240 format — many older/again budget devices top out at
    /// 720p240 — so we degrade gracefully instead of failing the session.
    private let preferredResolutions: [(width: Int32, height: Int32)] = [
        (1920, 1080),   // preferred: full 1080p
        (1280, 720),    // fallback:  720p still gives 240 FPS on most devices
    ]
    /// The resolution actually selected by `selectHighSpeedFormat`.
    private(set) var activeWidth: Int32 = 1920
    private(set) var activeHeight: Int32 = 1080
    /// 1/2000 s — fast enough to freeze a driver face at impact.
    private let shutter = CMTime(value: 1, timescale: 2000)

    // MARK: - Lifecycle

    func configure() throws {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority   // we drive format manually below

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .back) else {
            throw CaptureError.noCamera
        }
        self.device = device

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        try selectHighSpeedFormat(on: device)   // sets activeWidth/activeHeight
        try applyManualControls(on: device)

        // Build the encoder for the resolution we actually got (1080p or 720p),
        // so its VTCompressionSession dimensions match the incoming frames.
        encoder = VideoEncoder(width: activeWidth, height: activeHeight)
        // Encoder output → ring (via coordinator). Set before output is wired.
        encoder.onEncodedFrame = { [weak self] frame in self?.onEncodedFrame?(frame) }
        try encoder.start()

        videoOutput.alwaysDiscardsLateVideoFrames = true     // bound in-flight memory
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)  // NV12: encoder-native
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)
        guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAddOutput }
        session.addOutput(videoOutput)

        session.commitConfiguration()
        registerObservers()
    }

    // MARK: - Lifecycle / health observers

    /// Watch for interruptions (calls, control center, resource loss), runtime
    /// errors (which can stop the session mid-capture), and thermal pressure
    /// (sustained 240 FPS is a heat source — the UI may want to back off).
    private func registerObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                       name: .AVCaptureSessionWasInterrupted, object: session)
        nc.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                       name: .AVCaptureSessionInterruptionEnded, object: session)
        nc.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                       name: .AVCaptureSessionRuntimeError, object: session)
        nc.addObserver(self, selector: #selector(thermalStateChanged(_:)),
                       name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        var reason: AVCaptureSession.InterruptionReason?
        if let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int {
            reason = AVCaptureSession.InterruptionReason(rawValue: raw)
        }
        onStatusChange?(.interrupted(reason: reason))
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        onStatusChange?(.interruptionEnded)
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
        onStatusChange?(.runtimeError(error ?? CaptureError.unknown))
        // AVFoundation recommends restarting after a media-services-reset error.
        if let avError = error as? AVError, avError.code == .mediaServicesWereReset {
            sampleBufferQueue.async { [weak self] in self?.start() }
        }
    }

    @objc private func thermalStateChanged(_ note: Notification) {
        onStatusChange?(.thermalStateChanged(ProcessInfo.processInfo.thermalState))
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func start() { if !session.isRunning { session.startRunning() } }
    func stop()  { if session.isRunning  { session.stopRunning() }; encoder?.stop() }

    /// The clock video frame PTS are measured on. Hand this to the audio trigger
    /// so its impact timestamps land in the same timebase as the frames. On
    /// iOS 15.4+ this is `synchronizationClock`; older OSes use `masterClock`.
    var captureClock: CMClock? {
        if #available(iOS 15.4, *) { return session.synchronizationClock ?? session.masterClock }
        return session.masterClock
    }

    // MARK: - Format & manual controls

    /// Activate a ≥240 FPS format, preferring 1080p and falling back to 720p.
    /// You cannot simply *ask* for 240 FPS — you must match an AVCaptureDevice.Format,
    /// and not every device advertises one at 1080p, so we try each resolution in
    /// `preferredResolutions` order and take the first the hardware supports.
    private func selectHighSpeedFormat(on device: AVCaptureDevice) throws {
        var chosen: (format: AVCaptureDevice.Format, width: Int32, height: Int32)?
        for res in preferredResolutions {
            let match = device.formats.first { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let resOK = dims.width == res.width && dims.height == res.height
                let fpsOK = format.videoSupportedFrameRateRanges.contains {
                    $0.maxFrameRate >= targetFPS
                }
                return resOK && fpsOK
            }
            if let match {
                chosen = (match, res.width, res.height)
                break
            }
        }
        guard let chosen else { throw CaptureError.no240pFormat }

        activeWidth = chosen.width
        activeHeight = chosen.height

        try device.lockForConfiguration()
        device.activeFormat = chosen.format
        // Pin BOTH min and max frame duration to 1/240 → a hard, constant 240 FPS.
        let frameDuration = CMTime(value: 1, timescale: Int32(targetFPS))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
    }

    /// Lock exposure (fixed ≤1/2000 s shutter) and focus (infinity). Manual
    /// controls eliminate auto-exposure "hunting" between frames and keep club
    /// geometry undistorted for the CV stage.
    private func applyManualControls(on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // --- Exposure / shutter ---
        if device.isExposureModeSupported(.custom) {
            let fmt = device.activeFormat
            // Clamp 1/2000 s into the format's supported exposure range.
            let minD = fmt.minExposureDuration, maxD = fmt.maxExposureDuration
            let duration = CMTimeClampToRange(shutter, range: CMTimeRange(start: minD, end: maxD))
            // Mid ISO as a sane default; tune to ambient light in the field.
            let iso = min(max(fmt.minISO, 400), fmt.maxISO)
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
        }

        // --- Focus at infinity ---
        if device.isFocusModeSupported(.locked) &&
            device.isLockingFocusWithCustomLensPositionSupported {
            // lensPosition 1.0 == far / infinity.
            device.setFocusModeLockedWithLensPosition(1.0, completionHandler: nil)
        }

        // Lock white balance too so frame-to-frame color is stable for CV.
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = false }
    }

    enum CaptureError: Error { case noCamera, cannotAddInput, cannotAddOutput, no240pFormat, emptyWindow, unknown }
}

// MARK: - Frame intake

extension CameraSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Hot path — runs 240×/second. Keep it allocation-free and non-blocking.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dur = CMTime(value: 1, timescale: Int32(targetFPS))
        // Synchronous handoff to the hardware encoder; we do NOT retain
        // `pixelBuffer` past this call, so the capture pool recycles it.
        encoder.encode(pixelBuffer, pts: pts, duration: dur)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Late frame discarded by design — bounds memory under encoder pressure.
    }
}
