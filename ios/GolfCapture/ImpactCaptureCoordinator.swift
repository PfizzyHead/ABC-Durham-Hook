//
//  ImpactCaptureCoordinator.swift
//  GolfCapture — Phase 1: High-Speed Data Capture Engine
//
//  Top-level façade that wires the pipeline together:
//
//      CameraSessionManager ──encoded frames──▶ FrameRingBuffer (3 s pre-roll)
//      AudioTriggerManager  ──impact PTS──────▶ schedule export
//                                               │  wait for +1.5 s post-roll
//                                               ▼
//                                          ClipExporter ──▶ .mp4
//
//  On impact we record the trigger timestamp, keep capturing for the post-roll
//  duration, then slice [impact − 1.0 s, impact + 1.5 s] from the ring and dump
//  exactly those frames to disk.
//

import Foundation
import AVFoundation

final class ImpactCaptureCoordinator {

    /// Delivered when a swing clip has been written (or on failure).
    var onClipReady: ((Result<URL, Error>) -> Void)?

    /// Surfaces capture-session health (interruption, thermal, runtime error)
    /// so the UI can react. Forwarded straight from `CameraSessionManager`.
    var onStatusChange: ((CameraSessionManager.Status) -> Void)?

    private let camera = CameraSessionManager()
    private let audio = AudioTriggerManager()
    private let ring = FrameRingBuffer(capacity: 720)   // 3 s @ 240 FPS
    private let exporter = ClipExporter()

    private let preRoll  = CMTime(value: 1,  timescale: 1)   // 1.0 s before impact
    private let postRoll = CMTime(value: 15, timescale: 10)  // 1.5 s after impact

    private let work = DispatchQueue(label: "golf.coordinator")
    private var isExporting = false

    /// Request camera + microphone permission up front. Call before `startSession`.
    /// Completion is invoked on an arbitrary queue with `true` only if BOTH are granted.
    func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            guard videoOK else { completion(false); return }
            AVCaptureDevice.requestAccess(for: .audio) { audioOK in
                completion(audioOK)
            }
        }
    }

    func startSession() throws {
        // Encoded frames flow into the bounded ring buffer.
        camera.onEncodedFrame = { [weak self] frame in self?.ring.append(frame) }
        camera.onStatusChange = { [weak self] status in self?.onStatusChange?(status) }
        // Impact freezes the window and schedules a slice export.
        audio.onImpact = { [weak self] impactPTS in self?.handleImpact(at: impactPTS) }

        try camera.configure()
        // Align the audio trigger's timestamps to the video frame clock so the
        // pre/post-roll window is sliced accurately.
        audio.synchronizationClock = camera.captureClock
        camera.start()
        try audio.start()
    }

    func stopSession() {
        audio.stop()
        camera.stop()
        ring.reset()
    }

    // MARK: - Trigger handling

    private func handleImpact(at impactPTS: CMTime) {
        work.async { [weak self] in
            guard let self, !self.isExporting else { return }   // ignore until current export done
            self.isExporting = true

            let start = CMTimeSubtract(impactPTS, self.preRoll)
            let end   = CMTimeAdd(impactPTS, self.postRoll)

            // The post-roll frames don't exist yet — wait for the camera to
            // capture 1.5 s past impact, then slice the frozen window.
            let waitFor = self.postRoll.seconds + 0.05   // small guard margin
            self.work.asyncAfter(deadline: .now() + waitFor) {
                let slice = self.ring.frames(in: start, end)
                guard !slice.isEmpty else {
                    self.isExporting = false
                    self.onClipReady?(.failure(CameraSessionManager.CaptureError.emptyWindow))
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("swing-\(Int(Date().timeIntervalSince1970)).mp4")
                self.exporter.export(frames: slice, to: url) { result in
                    self.isExporting = false
                    self.onClipReady?(result)
                }
            }
        }
    }
}
