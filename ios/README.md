# GolfCapture — Phase 1: High-Speed Data Capture Engine

> ⚠️ **Repo note:** the rest of this repository (`ABC-Durham-Hook`) is a Node.js
> community-resources web app for Durham, NC. This `ios/` folder is an unrelated
> native iOS module added on the `claude/golf-launch-monitor-capture` branch
> because the branch is dedicated to that work. It is **not** wired into the web
> app and is intended to be lifted into a real Xcode project. There is no Swift
> toolchain in CI here, so the code has not been compiled in this environment.

Native iOS (Swift / AVFoundation) capture pipeline for a mobile golf launch
monitor. Locks the camera at **1080p @ 240 FPS**, freezes the club with a manual
**≤1/2000 s shutter** at **infinity focus**, keeps a rolling **3‑second** buffer
in RAM, and dumps a **2.5 s** clip (1.0 s pre + 1.5 s post impact) to MP4 when an
**acoustic impact trigger** fires.

## Architecture

```
AVCaptureDevice ─▶ AVCaptureVideoDataOutput ─▶ VideoEncoder ─▶ FrameRingBuffer
 (1080p/240/man.)        (NV12, discard-late)    (HW H.264)     (720 compressed)
                                                                      │
AVAudioEngine ─▶ AudioTriggerManager ─(impact PTS)─▶ ImpactCaptureCoordinator
 (mic tap)        (vDSP FFT: attack+brightness)            │ wait +1.5 s
                                                           ▼
                                                      ClipExporter ─▶ swing.mp4
```

| Type | Responsibility |
|------|----------------|
| `CameraSessionManager` | Owns `AVCaptureSession`; selects the 1080p/240 `AVCaptureDevice.Format`; locks manual exposure (1/2000 s), focus (∞) and white balance; feeds pixel buffers to the encoder. |
| `VideoEncoder` | VideoToolbox `VTCompressionSession`; real-time, no B-frames, short GOP; emits compressed `EncodedFrame`s. |
| `FrameRingBuffer` | Fixed 720-slot thread-safe FIFO of **compressed** frames (~3 s). O(1) append with self-evicting, bounded memory. |
| `AudioTriggerManager` | `AVAudioEngine` mic tap + `Accelerate` FFT; fires on a bright, fast transient (driver/iron impact) with a refractory window. |
| `ClipExporter` | Slices the impact window from the ring and writes the only per-swing disk file via `AVAssetWriter` (pass-through, re-timed to zero). |
| `ImpactCaptureCoordinator` | Façade that wires the pipeline and orchestrates the pre/post-roll slice on trigger. |

## Why the ring buffer is compressed (the core memory decision)

Raw 1080p is enormous, so a 720-frame **raw** buffer is a non-starter:

| Storage | Per frame | 720 frames (3 s) |
|---------|-----------|------------------|
| BGRA (4 B/px) | ~8.3 MB | **~6.0 GB** ❌ |
| NV12 (1.5 B/px) | ~3.1 MB | **~2.2 GB** ❌ |
| **H.264 (this design)** | ~5–40 KB | **~10–40 MB** ✅ |

Both raw options blow past the per-app jetsam limit and would overheat the device
just by touching that much memory at 240 Hz. Frames are therefore hardware-encoded
*before* entering the ring. Eviction drops the old `CMSampleBuffer` reference and
Core Media frees its backing store immediately, so steady-state RAM is flat no
matter how long the session runs.

## Memory & leak discipline (240 FPS)

- `alwaysDiscardsLateVideoFrames = true` bounds in-flight pixel memory if the
  encoder ever falls behind — no unbounded backlog.
- The capture callback hands the `CVPixelBuffer` to the encoder synchronously and
  never retains it, so the capture pool recycles its small fixed set of buffers.
- The audio FFT setup and scratch buffers are allocated once and reused — the
  audio render thread never allocates and has nothing to leak.
- Disk I/O happens **only** on a trigger (one MP4 per swing), never continuously.

## Integration

```swift
let coordinator = ImpactCaptureCoordinator()
coordinator.onClipReady = { result in
    switch result {
    case .success(let url): print("Swing clip: \(url)")
    case .failure(let err): print("Export failed: \(err)")
    }
}
try coordinator.startSession()   // requires camera + microphone permissions
```

Add to `Info.plist`: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`.

## Field-tuning knobs

- `AudioTriggerManager`: `attackRatio`, `brightnessRatio`, `highBandHz`, `refractory`.
- `CameraSessionManager`: `shutter` (default 1/2000 s) and the ISO clamp in
  `applyManualControls` — raise ISO for indoor/low light since the fast shutter
  starves the sensor.
- `VideoEncoder`: `keyframeInterval` — smaller = tighter slice boundaries, larger
  bitrate; swap `kCMVideoCodecType_H264` → HEVC for smaller buffers on A11+.
```
