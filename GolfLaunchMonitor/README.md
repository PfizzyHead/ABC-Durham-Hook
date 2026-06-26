# Golf Launch Monitor

A macOS application and offline computer-vision engine that turn a high-speed
golf-swing capture into launch-monitor metrics — **ball speed, launch angle, and
club path** — from video alone.

This repository contains two products:

| Folder | What it is |
| --- | --- |
| `SwingCaptureApp/` | A SwiftUI **iOS** app: the on-phone 240 FPS capture / data-collection tool (impact-triggered, saves the Phase-1 clip). |
| `SwingKinematicsEngine/` | A Swift + C++ Swift Package: the offline analysis engine (spatial calibration, CoreML detection scaffolding, kinematic vector math). |
| `GolfLaunchMonitorApp/` | A SwiftUI **macOS** app that consumes the engine: pick a capture, see the metrics (dev/analysis harness). |
| `MLModels/` | Python toolchain to capture-label-train: extract frames, auto-label the ball, train YOLOv8-nano, export to CoreML (`SwingDetector.mlpackage`). |

> **Platform:** Apple only (macOS 13+ / iOS 16+). The engine uses Vision/CoreML,
> AVFoundation, and Accelerate/simd, with a dependency-free C++ core bridged via
> Swift/C++ interop. Build with Xcode 15+ on a Mac.

## Pipeline

```
240 FPS MP4  ──►  AVAssetReader  ──►  CoreML detector  ──►  SwingKinematicsEngine
(1.0s pre +                          (YOLOv8-nano:                    │
 1.5s post impact)                    club_head /                     ▼
                                      ball_static /            ball speed (mph)
                                      ball_flight)             launch angle (°)
                                                              club path / attack (°)
```

See `SwingKinematicsEngine/README.md` for the full mathematical framework.

## Build & run

```bash
# 1. Engine unit tests (pure math, no UI):
swift test --package-path SwingKinematicsEngine

# 2. Generate and open the app project:
brew install xcodegen           # one time
cd GolfLaunchMonitorApp
xcodegen generate
open GolfLaunchMonitor.xcodeproj
```

Set your Team under **Signing & Capabilities**, change the bundle-ID prefix in
`GolfLaunchMonitorApp/project.yml` from `com.example` to your organization's, then
**⌘R**.

## Status

The engine and app are fully wired, and the app **auto-loads** a bundled
`SwingDetector` CoreML model on launch. The one remaining input is the model
itself — a **YOLOv8-nano trained on `[club_head, ball_static, ball_flight]`**.
Produce it with the `MLModels/` toolchain, drag the resulting
`SwingDetector.mlpackage` into the app target, and it works with no code change.
Until then the app intentionally reports that no model is loaded rather than
producing misleading numbers.

## License

© the project's owning organization. All rights reserved. Replace this section
with your chosen license before publishing.
