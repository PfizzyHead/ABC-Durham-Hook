//
//  AudioTriggerManager.swift
//  GolfCapture — Phase 1: High-Speed Data Capture Engine
//
//  Continuously listens via AVAudioEngine for the acoustic signature of a club
//  striking a ball — a sharp, broadband transient with strong high-frequency
//  energy (driver/iron "crack", energy concentrated ~2–8 kHz). When detected it
//  fires `onImpact` so the coordinator can freeze the ring buffer.
//
//  ──────────────────────────────────────────────────────────────────────────
//  DETECTION STRATEGY
//  ──────────────────────────────────────────────────────────────────────────
//  Two conditions must BOTH hold to count as an impact (rejects voices, wind,
//  clothing rustle, and steady noise):
//    1. ATTACK    — instantaneous RMS jumps well above the running ambient floor
//                   (a fast onset, not a gradual rise).
//    2. BRIGHTNESS — a large fraction of the frame's energy sits in the high
//                   band (impact is "bright"; speech/wind are low-frequency).
//  A refractory window then suppresses re-triggering on the ringing tail.
//
//  ──────────────────────────────────────────────────────────────────────────
//  MEMORY / LATENCY NOTES
//  ──────────────────────────────────────────────────────────────────────────
//  • The FFT setup (`vDSP_DFT_Setup`) and all scratch buffers are allocated ONCE
//    and reused for every block — the audio tap never allocates on its hot path,
//    so there is no per-block churn and nothing to leak.
//  • A small block size (1024 ≈ 21 ms @ 48 kHz) keeps trigger latency low, which
//    matters because the 1.0 s pre-roll is measured backwards from this instant.
//

import Foundation
import AVFoundation
import Accelerate

final class AudioTriggerManager {

    /// Fired on impact with the impact timestamp expressed on the **capture
    /// session's clock** (when `synchronizationClock` is set), so it can be
    /// compared directly against video frame PTS for accurate slicing.
    var onImpact: ((CMTime) -> Void)?

    /// The capture session's clock (`AVCaptureSession.synchronizationClock`).
    /// The audio tap reports times on the host-time clock; we convert onto this
    /// clock so audio impacts and video PTS live in the same timebase. If nil we
    /// fall back to the raw host time (correct only if video also uses it).
    var synchronizationClock: CMClock?

    private let engine = AVAudioEngine()
    private let blockSize = 1024
    private let log2n: vDSP_Length
    private let fftSetup: vDSP_DFT_Setup?

    // Reusable scratch — allocated once (see memory note above).
    private var window: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]

    // Adaptive ambient floor (slow EMA) and refractory state.
    private var ambientRMS: Float = 1e-4
    private var lastTriggerTime: CFTimeInterval = 0
    private let refractory: CFTimeInterval = 0.5      // ignore tail/echo for 0.5 s

    // Tunables — exposed as `var` so they can be calibrated in the field
    // (e.g. from a debug UI) without recompiling. Defaults are conservative
    // starting points for an outdoor driver/iron impact.
    var attackRatio: Float = 6.0      // onset must be ≥6× ambient floor
    var brightnessRatio: Float = 0.45 // ≥45% of energy in the high band
    var highBandHz: Float = 2000      // "high" starts here

    init() {
        self.log2n = vDSP_Length(log2(Float(blockSize)))
        self.fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(blockSize), .FORWARD)
        self.window     = [Float](repeating: 0, count: blockSize)
        self.real       = [Float](repeating: 0, count: blockSize)
        self.imag       = [Float](repeating: 0, count: blockSize)
        self.magnitudes = [Float](repeating: 0, count: blockSize / 2)
        vDSP_hann_window(&window, vDSP_Length(blockSize), Int32(vDSP_HANN_NORM))
    }

    func start() throws {
        let sessionAudio = AVAudioSession.sharedInstance()
        try sessionAudio.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
        try sessionAudio.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = Float(format.sampleRate)

        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(blockSize), format: format) {
            [weak self] buffer, time in
            self?.process(buffer, sampleRate: sampleRate, time: time)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit {
        if let fftSetup { vDSP_DFT_DestroySetup(fftSetup) }
    }

    // MARK: - Hot path (audio render thread) — no allocations

    /// Pure detection decision, split out so the attack+brightness gating is
    /// unit-testable without driving real audio through the engine. An impact is
    /// a fast onset (RMS well above the ambient floor) AND a bright spectrum.
    static func isImpact(rms: Float, ambient: Float, brightness: Float,
                         attackRatio: Float, brightnessRatio: Float) -> Bool {
        let isAttack = rms > ambient * attackRatio
        let isBright = brightness >= brightnessRatio
        return isAttack && isBright
    }

    private func process(_ buffer: AVAudioPCMBuffer, sampleRate: Float, time: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n >= blockSize else { return }

        // 1) Broadband RMS for the attack/onset test.
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(blockSize))

        // 2) Windowed FFT → magnitude spectrum for the brightness test.
        vDSP_vmul(channel, 1, window, 1, &real, 1, vDSP_Length(blockSize))
        imag.withUnsafeMutableBufferPointer { imagPtr in
            real.withUnsafeMutableBufferPointer { realPtr in
                let zeros = [Float](repeating: 0, count: blockSize)
                vDSP_DFT_Execute(fftSetup!, realPtr.baseAddress!, zeros,
                                 realPtr.baseAddress!, imagPtr.baseAddress!)
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(blockSize / 2))
            }
        }

        // Energy split: total vs. the high band (≥ highBandHz).
        let binHz = sampleRate / Float(blockSize)
        let highBin = min(Int(highBandHz / binHz), magnitudes.count - 1)
        var total: Float = 0, high: Float = 0
        vDSP_sve(magnitudes, 1, &total, vDSP_Length(magnitudes.count))
        vDSP_sve(Array(magnitudes[highBin...]), 1, &high, vDSP_Length(magnitudes.count - highBin))
        let brightness = total > 0 ? high / total : 0

        let trigger = Self.isImpact(rms: rms, ambient: ambientRMS, brightness: brightness,
                                    attackRatio: attackRatio, brightnessRatio: brightnessRatio)

        if trigger {
            let now = CACurrentMediaTime()
            if now - lastTriggerTime > refractory {
                lastTriggerTime = now
                // The tap's hostTime is on the host-time clock. Convert it onto
                // the capture session's clock so the impact instant lines up with
                // video frame PTS (sub-frame accurate pre-roll). Without a sync
                // clock we return the host time unchanged.
                let hostClock = CMClockGetHostTimeClock()
                let impactHost = CMClockMakeHostTimeFromSystemUnits(time.hostTime)
                let impact: CMTime
                if let syncClock = synchronizationClock {
                    impact = CMSyncConvertTime(impactHost, from: hostClock, to: syncClock)
                } else {
                    impact = impactHost
                }
                onImpact?(impact)
            }
        } else {
            // Update the ambient floor only on non-impact blocks (slow EMA).
            ambientRMS = ambientRMS * 0.95 + rms * 0.05
        }
    }
}
