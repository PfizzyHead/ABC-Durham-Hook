# GolfCapture — Phase 1 Handoff Brief (for ChatGPT Codex)

This single document is a self-contained handoff. It bundles the original
requirements, the architecture, every design decision, the done/not-done state,
how to build & test, the known risks, and an explicit task list. If you have
repo access, also read `ios/STATUS.md` and `ios/README.md` — this file is a
superset summary of both.

---

## 0. How to pick this up

- **Repo:** `PfizzyHead/ABC-Durham-Hook`
- **Branch:** `claude/golf-launch-monitor-capture-7pROZ` (NOT `master` — `master`
  is an unrelated Node.js "website change monitor" web app).
- **All iOS code lives under `ios/`.** Nothing outside `ios/` and
  `.github/workflows/ios-tests.yml` is part of this module.
- **State:** code-complete for everything achievable without an iOS device.
  **Nothing has been compiled** — the authoring environment had no Swift
  toolchain. The first macOS CI run / your first build is the real compile check.

### Suggested first prompt to yourself (Codex)
> Build `ios/Package.swift` and run the unit tests on the iOS Simulator
> (`xcodebuild test -scheme GolfCapture -destination 'platform=iOS Simulator,name=iPhone 15'`).
> Fix any compile errors. Then work through Section 6 "Remaining work" below.

---

## 1. Product context

Phase 1 of a mobile golf launch monitor: an on-device, high-speed video capture
engine. It continuously films the swing, listens for the club-ball impact sound,
and saves a short clip around impact for a later computer-vision stage (Phase 2).

**Target:** Native iOS (Swift) · AVFoundation / VideoToolbox / AVAudioEngine / Accelerate.

---

## 2. Original requirements (the brief) and how each was met

| # | Requirement | How it's implemented |
|---|---|---|
| 1 | Lock camera at **1080p @ 240 FPS** | `CameraSessionManager.selectHighSpeedFormat` matches an `AVCaptureDevice.Format` that is 1080p AND advertises ≥240 FPS, then pins min＝max frame duration to 1/240 for a hard constant rate. **Adds a 720p240 fallback** for devices lacking a native 1080p240 format. |
| 2 | Manual **shutter ≥1/2000 s**, **focus ∞** | `applyManualControls`: `setExposureModeCustom` (1/2000 s clamped to format range), `setFocusModeLockedWithLensPosition(1.0)`. White balance also locked for CV stability. |
| 3 | **FIFO ring buffer**, 3 s / 720 frames, RAM, no continuous disk | `FrameRingBuffer` (720 slots) holds **compressed** frames from `VideoEncoder`. See Design Decision below. |
| 4 | **Acoustic trigger** via AVAudioEngine | `AudioTriggerManager`: mic tap + vDSP FFT; fires on attack (RMS ≫ adaptive floor) AND brightness (≥45% energy >2 kHz), with a 0.5 s refractory window. |
| 5 | On trigger: **1.0 s pre + 1.5 s post** → **MP4** | `ImpactCaptureCoordinator` records impact PTS, waits 1.5 s, slices the window; `ClipExporter` writes one MP4 via `AVAssetWriter` (pass-through, re-timed to zero). |

---

## 3. THE key design decision — compressed ring buffer (read this)

The brief literally said "raw frames." A 720-frame **raw** buffer is impossible on-device:

| Storage | Per frame | 720 frames (3 s) |
|---|---|---|
| BGRA raw | ~8.3 MB | **~6.0 GB** ❌ exceeds jetsam → instant kill |
| NV12 raw | ~3.1 MB | **~2.2 GB** ❌ exceeds jetsam → instant kill |
| **H.264 (chosen)** | ~5–40 KB | **~10–40 MB** ✅ |

So frames are **hardware-encoded (VideoToolbox) before entering the ring.** This
keeps the 3 s buffer at tens of MB, runs on the dedicated media block (low heat —
satisfies "don't overheat"), and a short GOP guarantees any carved clip starts on
a decodable keyframe. The only disk write is the per-swing MP4. **Do not revert
this to raw frames** unless the buffer duration shrinks drastically.

---

## 4. Architecture

```
AVCaptureDevice ─▶ AVCaptureVideoDataOutput ─▶ VideoEncoder ─▶ FrameRingBuffer
 (1080p/240/man.)        (NV12, discard-late)    (HW H.264)     (720 compressed)
                                                                      │
AVAudioEngine ─▶ AudioTriggerManager ─(impact PTS)─▶ ImpactCaptureCoordinator
 (mic tap)        (vDSP FFT: attack+brightness)            │ wait +1.5s
                                                           ▼
                                                      ClipExporter ─▶ swing.mp4
```

| File (`ios/GolfCapture/`) | Responsibility |
|---|---|
| `CameraSessionManager.swift` | Session; format selection (1080p→720p @240); manual exposure/focus/WB; lifecycle + thermal observers (`onStatusChange`); exposes `captureClock`. |
| `VideoEncoder.swift` | `VTCompressionSession`; real-time, no B-frames, short GOP; emits `EncodedFrame`. |
| `FrameRingBuffer.swift` | 720-slot thread-safe FIFO of compressed frames; O(1) self-evicting; `windowIndices` does keyframe-aligned slicing (pure, unit-tested). |
| `AudioTriggerManager.swift` | AVAudioEngine tap + Accelerate FFT; `isImpact` gating (pure, unit-tested); clock-aligned impact timestamps. |
| `ClipExporter.swift` | Slices the window, re-times to zero, writes one MP4 via `AVAssetWriter`. |
| `ImpactCaptureCoordinator.swift` | Façade: `requestPermissions`, wiring, clock injection, pre/post-roll orchestration, status forwarding. |
| `Info.plist.sample` | Required `NSCameraUsageDescription` / `NSMicrophoneUsageDescription` keys. |

Tests in `ios/GolfCaptureTests/`: `FrameRingBufferTests` (FIFO/eviction/slicing),
`AudioTriggerTests` (gating decision).

---

## 5. Memory & thermal posture (the brief's emphasis)

- Ring bounded by construction (≤720 refs); eviction frees the backing
  `CMSampleBuffer` immediately → flat steady-state RAM.
- `alwaysDiscardsLateVideoFrames = true` → no unbounded backlog under encoder pressure.
- Capture callback never retains the `CVPixelBuffer` → fixed capture pool recycles.
- Audio FFT setup + scratch allocated once, reused → allocation-free render thread.
- Disk I/O only on trigger (one MP4 per swing), never continuous.

---

## 6. Remaining work (your job, Codex)

**Device-free (do first, CI/Simulator catches these):**
0. **Compile.** Build the package and run the Simulator tests (commands in §7).
   Fix any compile errors — likely candidates: API `@available` nits, an
   `iPhone 15` simulator-name mismatch on the runner image, or `CMSampleBuffer`
   test-helper API signatures. This code was never compiled.
1. Confirm the two unit suites pass; expand coverage if useful (e.g. ring
   wrap-around edge cases, refractory-window behaviour).

**Requires a physical iOS device (240 FPS hardware):**
2. On-device smoke test: verify 1080p240 lock (and 720p240 fallback path),
   manual shutter/focus actually engage.
3. **Acoustic-trigger calibration:** the gating logic is tested, but the numeric
   thresholds (`attackRatio`, `brightnessRatio`, `highBandHz`, `refractory`) must
   be tuned against real driver/iron impacts vs. range noise. They're runtime-`var`s.
4. End-to-end timing: confirm the pre/post-roll window lands correctly once the
   audio→video sync-clock conversion runs against live capture.
5. Long-session thermal/battery profiling; wire a UI backoff policy to `onStatusChange`.
6. Storage policy: clips currently go to `temporaryDirectory` — decide retention,
   cleanup, and a permanent location for processed swings.

---

## 7. Build & test (no physical device needed)

The module is **iOS-only** (imports `AVAudioSession`; uses manual `AVCaptureDevice`
controls that don't exist on macOS), so a bare `swift test` on the macOS host will
**not** compile. Use the iOS Simulator:

```sh
cd ios
xcodebuild test \
  -scheme GolfCapture \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  CODE_SIGNING_ALLOWED=NO
```

CI runs exactly this on any `ios/**` change — `.github/workflows/ios-tests.yml`
(`macos-14` runner). The Simulator exercises only the pure logic, not live capture.

---

## 8. Known risks / caveats (be honest with yourself)

- **Uncompiled.** Everything here is "code complete, build-pending." Treat the
  first green CI run as the first real validation.
- **Simulator name assumption.** `iPhone 15` must exist on the runner image; if
  not, pick an available one (`xcrun simctl list devicetypes`).
- **Clock alignment** uses `CMSyncConvertTime` from host clock → capture
  `synchronizationClock` (`masterClock` pre-iOS 15.4). Correct in theory; needs
  device validation for sub-frame accuracy.
- **Not every device has 1080p240** — hence the 720p fallback; both paths need
  on-device checks.
- This was authored by a different agent (Claude). No agent is now watching the
  branch — it's yours.
```
