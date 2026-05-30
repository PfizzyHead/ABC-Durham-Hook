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

    let session = AVCaptureSession()
    private let sampleBufferQueue = DispatchQueue(label: "golf.capture.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let encoder = VideoEncoder()
    private var device: AVCaptureDevice?

    private let targetFPS: Double = 240
    private let targetWidth: Int32 = 1920
    private let targetHeight: Int32 = 1080
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

        try selectHighSpeedFormat(on: device)
        try applyManualControls(on: device)

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
    }

    func start() { if !session.isRunning { session.startRunning() } }
    func stop()  { if session.isRunning  { session.stopRunning() }; encoder.stop() }

    // MARK: - Format & manual controls

    /// Find and activate the format that is exactly 1080p and supports ≥240 FPS.
    /// You cannot simply *ask* for 240 FPS — you must match an AVCaptureDevice.Format.
    private func selectHighSpeedFormat(on device: AVCaptureDevice) throws {
        let match = device.formats.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let resOK = dims.width == targetWidth && dims.height == targetHeight
            let fpsOK = format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= targetFPS
            }
            return resOK && fpsOK
        }
        guard let format = match else { throw CaptureError.no240pFormat }

        try device.lockForConfiguration()
        device.activeFormat = format
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

    enum CaptureError: Error { case noCamera, cannotAddInput, cannotAddOutput, no240pFormat }
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
