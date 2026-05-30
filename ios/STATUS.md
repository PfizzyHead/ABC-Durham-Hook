# Phase 1 — High-Speed Data Capture Engine · Status Report

**Date:** 2026-05-30
**Branch:** `claude/golf-launch-monitor-capture-7pROZ`
**PR:** [#1 — Phase 1: High-Speed Golf Capture Engine (iOS/Swift)](https://github.com/PfizzyHead/ABC-Durham-Hook/pull/1)
**Target platform:** Native iOS (Swift) · AVFoundation / VideoToolbox / AVAudioEngine / Accelerate

> **Repo context:** the surrounding repository is a Node.js web app. This capture
> engine is isolated under `ios/` and does not touch the web app. It is written to
> be lifted into a real Xcode project. **It has not been compiled** — there is no
> Swift toolchain in this environment, so everything below is "code complete,
> compile/run pending on device."

---

## Requirements traceability

| # | Requirement (from the brief) | Status | Where |
|---|------------------------------|--------|-------|
| 1 | Lock AVCaptureDevice at **1080p @ 240 FPS** | ✅ Done (+720p fallback) | `CameraSessionManager.selectHighSpeedFormat` |
| 2 | Manual controls: fixed shutter **≥1/2000 s**, focus **∞** | ✅ Done | `CameraSessionManager.applyManualControls` |
| 3 | **FIFO ring buffer**, exactly 3 s / 720 frames, in memory, no continuous disk | ✅ Done (compressed) | `FrameRingBuffer` + `VideoEncoder` |
| 4 | **Acoustic trigger** via AVAudioEngine, continuous high-freq spike detection | ✅ Done | `AudioTriggerManager` |
| 5 | On trigger: freeze buffer, **1.0 s pre + 1.5 s post**, dump to **MP4** | ✅ Done | `ImpactCaptureCoordinator` + `ClipExporter` |
| — | Architectural class design | ✅ Done | this doc + `ios/README.md` |
| — | Inline memory-footprint documentation | ✅ Done | header comments in every file |

---

## Requirement-by-requirement detail

### 1. 1080p @ 240 FPS lock — ✅
- `selectHighSpeedFormat` enumerates `device.formats` and activates the first that
  matches the target resolution **and** advertises `maxFrameRate ≥ 240`. You cannot
  request 240 FPS directly; you must match an `AVCaptureDevice.Format`.
- Both `activeVideoMinFrameDuration` and `activeVideoMaxFrameDuration` are pinned to
  `1/240`, forcing a **hard constant** 240 FPS (no auto frame-rate dipping).
- **Enhancement beyond brief:** a 720p240 fallback (`preferredResolutions`) so the
  session still runs on devices that lack a native 1080p240 format, rather than
  failing. The encoder is sized to whichever resolution is actually selected.

### 2. Manual exposure + focus — ✅
- **Shutter:** `setExposureModeCustom` with `1/2000 s`, clamped into the format's
  `[minExposureDuration, maxExposureDuration]` range, ISO defaulted mid-range.
  This freezes a 100+ mph club face and removes auto-exposure hunting between frames.
- **Focus:** `setFocusModeLockedWithLensPosition(1.0)` = infinity, locked.
- **Bonus:** white balance locked too, for frame-to-frame color stability for the CV stage.

### 3. 3-second FIFO ring buffer — ✅ (with the one substantive design call)
- `FrameRingBuffer` is a fixed **720-slot** (3 s × 240 FPS) circular buffer; O(1)
  append, oldest frame self-evicts when full. Thread-safe via a single lock.
- **Design decision — frames are stored COMPRESSED, not raw.** A 720-frame *raw*
  buffer is infeasible on-device:

  | Storage | Per frame | 720 frames |
  |---|---|---|
  | BGRA raw | ~8.3 MB | **~6.0 GB** ❌ |
  | NV12 raw | ~3.1 MB | **~2.2 GB** ❌ |
  | **H.264 (chosen)** | ~5–40 KB | **~10–40 MB** ✅ |

  Raw exceeds the per-app jetsam limit (instant kill) and continuously touching
  gigabytes at 240 Hz is exactly the overheating the brief wants to avoid. Frames are
  hardware-encoded (`VideoEncoder` / VideoToolbox) before entering the ring. **No
  continuous disk writes** — the ring lives entirely in RAM.

### 4. Acoustic impact trigger — ✅
- `AudioTriggerManager` installs an `AVAudioEngine` input tap and runs a windowed
  vDSP FFT on each ~21 ms block, continuously.
- Fires only when **both** conditions hold (rejects speech, wind, clothing):
  1. **Attack** — instantaneous RMS ≥ 6× an adaptive ambient floor (fast onset).
  2. **Brightness** — ≥45% of spectral energy above 2 kHz (impact "crack" is bright).
- A 0.5 s **refractory window** suppresses re-triggering on the ringing tail.

### 5. Freeze + slice + MP4 export — ✅
- On trigger, `ImpactCaptureCoordinator` records the impact PTS, waits ~1.5 s for the
  post-roll frames to accumulate, then slices `[impact − 1.0 s, impact + 1.5 s]` from
  the ring (snapped back to the nearest keyframe so the clip is decodable).
- `ClipExporter` re-times the slice to t=0 and pass-through writes a single `.mp4`
  via `AVAssetWriter` — **the only disk write per swing.**

---

## Deliverables (files)

| File | Lines | Purpose |
|---|---|---|
| `ios/GolfCapture/CameraSessionManager.swift` | ~190 | Capture session, 1080p/720p@240 format, manual controls |
| `ios/GolfCapture/VideoEncoder.swift` | ~114 | Hardware H.264 encode (VideoToolbox) |
| `ios/GolfCapture/FrameRingBuffer.swift` | ~114 | 720-slot compressed FIFO ring |
| `ios/GolfCapture/AudioTriggerManager.swift` | ~144 | AVAudioEngine + vDSP impact detection |
| `ios/GolfCapture/ClipExporter.swift` | ~97 | Slice → MP4 export |
| `ios/GolfCapture/ImpactCaptureCoordinator.swift` | ~83 | Pipeline façade / orchestration |
| `ios/README.md` | — | Architecture + integration guide |

**Commits:** `f81cc15` (engine) · `119551b` (720p240 fallback)

---

## Memory & thermal posture (the brief's emphasis)

- Ring bounded by construction (≤720 refs); eviction frees backing store immediately → flat RAM.
- `alwaysDiscardsLateVideoFrames = true` → no unbounded backlog under encoder pressure.
- Capture callback never retains the `CVPixelBuffer` → fixed-depth capture pool recycles.
- Audio FFT setup + scratch allocated once, reused → allocation-free render thread, nothing to leak.
- Encoding on the dedicated media block; disk I/O only on trigger → minimal heat.

---

## Known limitations / follow-ups before this is device-ready

These are **not yet done** and are recommended next steps:

1. **Not compiled / not run.** Needs a build + on-device smoke test on real 240 FPS hardware.
2. **Clock alignment.** Audio→video correlation uses the host clock. For sub-frame-accurate
   pre-roll, drive both off the capture session's `synchronizationClock`.
3. **Trigger tuning.** `attackRatio`, `brightnessRatio`, `highBandHz`, `refractory` need
   field calibration against real driver/iron impacts vs. ambient range noise.
4. **Permissions / lifecycle.** Add `Info.plist` usage strings; handle interruptions
   (calls, backgrounding), thermal-state throttling, and storage cleanup of old clips.
5. **No automated tests.** Ring-buffer eviction/slicing logic is unit-testable on macOS
   without a device — worth adding.

---

## Where we are

**Phase 1 is code-complete against all five requirements**, plus a robustness enhancement
(720p fallback) and full inline + README documentation. The single notable deviation from
the literal brief — storing the ring buffer compressed rather than raw — was a necessary
call to keep the 3 s buffer under ~40 MB instead of ~2–6 GB, which is what makes the
"no overheating, no continuous disk" goal achievable at all.

**Outstanding before production:** compile + on-device validation, clock-alignment hardening,
acoustic-trigger field calibration, and lifecycle/permissions plumbing (items 1–5 above).
