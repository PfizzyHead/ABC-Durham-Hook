# SwingKinematicsEngine

Phase 2 of the Golf Launch Monitor: an **offline** Swift/C++ framework that ingests
the Phase-1 capture (1080p, 240 FPS MP4 — 1.0 s pre-impact + 1.5 s post-impact ≈
600 frames) and derives swing kinematics frame-by-frame.

> **Platform:** Apple only (iOS 16+ / macOS 13+). It depends on **Vision/CoreML**
> (detection), **AVFoundation** (decoding) and **Accelerate/simd** (math), plus a
> dependency-free **C++** core bridged via Swift/C++ interop. It builds with Xcode
> or `swift build` on macOS; it does **not** compile on Linux (no Apple SDKs).

---

## Pipeline

```
MP4 ──► VideoFrameProvider ──► SwingObjectDetector ──► [FrameDetections]
        (AVAssetReader)        (YOLOv8-nano / CoreML)          │
                                                               ▼
                                            SwingKinematicsEngine.analyze
                                                               │
        ┌──────────────────────────┬───────────────────────────┴───────────┐
        ▼                          ▼                                         ▼
 SpatialCalibrator          BallSpeedCalculator                     ClubPathCalculator
 (mm/pixel, lens Z)         LaunchAngleCalculator                   (C++ covariance PCA)
                                                               │
                                                               ▼
                                                         SwingMetrics
```

`analyze(provider:)` runs the full decode→detect→measure path. `analyze(frames:)`
runs the **pure math** over pre-collected detections — no video, no model — and is
what the unit tests exercise.

---

## 1. Spatial calibration  (`SpatialCalibrator`)

A regulation golf ball has a known diameter **D = 1.68 in = 42.672 mm**. In the
static pre-impact frames the detector reports the ball's pixel diameter `d_px`
(averaged across both box axes; **median** taken across frames for robustness).
The master scale factor is the similar-triangles ratio at the ball's depth plane:

```
mmPerPixel  s = D_mm / d_px
```

With camera intrinsics (focal length `f` in px) the pinhole model also recovers
the lens-to-ball distance:

```
Z = f · D_mm / d_px        (image_diameter / f = real_diameter / Z)
```

Every downstream measurement converts pixels → millimeters through `s`.

## 2. Detection scaffolding  (`SwingObjectDetector`)

A `Sendable` protocol: `detect(in: VideoFrame) async throws -> [Detection]`,
emitting boxes for `club_head`, `ball_static`, `ball_flight`.

- **`CoreMLObjectDetector`** — production path. Wraps a CoreML model (YOLOv8-nano
  exported to `.mlmodelc`) in a `VNCoreMLRequest`, maps
  `VNRecognizedObjectObservation` → `Detection`, and converts Vision's normalized
  bottom-left boxes into pixel-space top-left boxes. A `labelMap` adapts models
  whose class strings differ from ours.
- **`ScriptedDetector`** — test/replay path returning canned detections per frame.

## 3. Kinematic vectors

World frame is right-handed: **+X downrange, +Y lateral, +Z up**. Image space is
top-left origin with +y **down**, so "up" is `−y`.

### Ball speed  (`BallSpeedCalculator`)
Each ball-flight center over the first `N=5` post-impact frames is converted to
mm `(X = x·s, Z = −y·s)`. Per-axis velocity is the **ordinary-least-squares
slope** of position vs. time (Accelerate `vDSP` — `meanvD`, `vsaddD`, `dotprD`),
which is the ML velocity estimate under Gaussian position noise and rejects
per-frame jitter far better than a two-frame difference:

```
v_axis = Σ(tᵢ−t̄)(pᵢ−p̄) / Σ(tᵢ−t̄)²
speed  = ‖(v_X, v_Z)‖   [mm/s] → /1000 → m/s → ×2.236936 → mph
```

### Launch angle  (`LaunchAngleCalculator`)
Vertical departure relative to the ground plane, from the same velocity vector:

```
θ = atan2(v_up, |v_downrange|)
```

`|v_downrange|` makes the angle independent of swing/camera handedness; the signed
vertical term preserves the rare negative launch.

### Club path  (`ClubPathCalculator`)
The 3-D travel direction of the club-head center over the last `N=6` frames into
the ball. Centers are back-projected to world mm, then the **dominant principal
axis** (best-fit line) is extracted by the C++ core `skc::principalDirection3`
(mean-centered 3×3 covariance → symmetric power iteration). From the unit
direction:

```
clubPathAngle (face) = atan2(dir_Y, dir_X)          [ground plane]
attackAngle          = atan2(dir_Z, ‖(dir_X,dir_Y)‖) [vertical]
```

**Single-camera caveat (made explicit in code):** one view observes one plane.
`PlanarVerticalBackProjector` (side-on / down-the-line) yields the **attack angle**
in the vertical plane (lateral ≡ 0). `GroundPlaneHomographyBackProjector` (overhead,
3×3 homography) yields the **face/path angle** on the turf. A genuine 3-D path
needs both views fused; the `WorldBackProjector` protocol is the seam for that.

---

## Why C++

`KinematicsCore` owns the one primitive Accelerate doesn't hand you directly — the
3×3 covariance eigen-solve for the club-path best-fit line — kept dependency-free
(`<cmath>` only) and bridged through `.interoperabilityMode(.Cxx)`. The Swift layer
keeps orchestration, unit handling, and the vDSP regressions.

## Layout

```
Sources/KinematicsCore/                C++ PCA core (+ umbrella header)
Sources/SwingKinematicsEngine/
  Core/         Geometry, Detection, frame models
  Calibration/  SpatialCalibrator, BackProjection
  Detection/    SwingObjectDetector protocol, CoreML + scripted impls
  Kinematics/   LinearRegression (vDSP), BallSpeed, LaunchAngle, ClubPath
  Pipeline/     VideoFrameProvider (AVAssetReader), SwingKinematicsEngine
  Models/       SwingMetrics
Tests/          Synthetic-trajectory unit tests for all three metrics
```

## Usage

```swift
let provider = try await AVAssetReaderFrameProvider(url: clipURL)
let model    = try MLModel(contentsOf: compiledModelURL)
let detector = try CoreMLObjectDetector(model: model)

let engine   = SwingKinematicsEngine(
    detector: detector,
    configuration: .init(intrinsics: CameraIntrinsics(focalLengthPixels: 1500))
)

let metrics = try await engine.analyze(provider: provider)
print(metrics.ballSpeed.milesPerHour, metrics.launchAngle.degrees,
      metrics.clubPath.attackAngleDegrees)
```
