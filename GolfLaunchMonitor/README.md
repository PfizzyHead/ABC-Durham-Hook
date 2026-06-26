# Golf Launch Monitor

A macOS application and offline computer-vision engine that turn a high-speed
golf-swing capture into launch-monitor metrics — **ball speed, launch angle, and
club path** — from video alone.

This repository contains two products:

| Folder | What it is |
| --- | --- |
| `SwingKinematicsEngine/` | A Swift + C++ Swift Package: the offline analysis engine (spatial calibration, CoreML detection scaffolding, kinematic vector math). |
| `GolfLaunchMonitorApp/` | A SwiftUI macOS app that consumes the engine: pick a capture, see the metrics. |

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

The engine and app are fully wired. The one remaining input is a **YOLOv8-nano
object-detection model trained on `[club_head, ball_static, ball_flight]`,
exported to CoreML**. Until it is bundled, the app intentionally reports that no
model is loaded rather than producing misleading numbers. Wire the model into
`SwingAnalysisViewModel.makeDetector` (snippet in that file).

## License

© the project's owning organization. All rights reserved. Replace this section
with your chosen license before publishing.
