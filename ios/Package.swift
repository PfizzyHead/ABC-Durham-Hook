// swift-tools-version:5.9
//
//  Package.swift — GolfCapture (Phase 1 high-speed capture engine)
//
//  Defines a build + test target over the existing folder layout so the engine
//  compiles and the unit tests run in CI without a hand-built Xcode project.
//  No files are moved: the targets point straight at the existing `GolfCapture/`
//  and `GolfCaptureTests/` directories.
//
//  WHY iOS-ONLY (and not plain `swift test` on macOS):
//  The engine imports AVAudioSession and uses iOS-only AVCaptureDevice manual
//  controls (setExposureModeCustom, setFocusModeLockedWithLensPosition, white-
//  balance lock, capture-session interruption notifications). None of those
//  exist on macOS, so the module does not compile for the macOS host that a bare
//  `swift test` would target. The unit suites therefore run on the **iOS
//  Simulator** — which needs no physical device — via xcodebuild:
//
//      xcodebuild test \
//        -scheme GolfCapture \
//        -destination 'platform=iOS Simulator,name=iPhone 15'
//
//  (See ../.github/workflows/ios-tests.yml for the CI invocation.)
//  Live camera/mic capture still requires a real iOS device; the simulator only
//  exercises the pure logic (ring-buffer slicing, trigger gating).
//
import PackageDescription

let package = Package(
    name: "GolfCapture",
    platforms: [
        .iOS(.v15),   // synchronizationClock paths are #available-gated to 15.4
    ],
    products: [
        .library(name: "GolfCapture", targets: ["GolfCapture"]),
    ],
    targets: [
        .target(
            name: "GolfCapture",
            path: "GolfCapture",
            // Info.plist.sample is documentation, not a build resource.
            exclude: ["Info.plist.sample"]
        ),
        .testTarget(
            name: "GolfCaptureTests",
            dependencies: ["GolfCapture"],
            path: "GolfCaptureTests"
        ),
    ]
)
