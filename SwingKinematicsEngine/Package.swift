// swift-tools-version: 5.9
import PackageDescription

// SwingKinematicsEngine — offline (post-capture) swing-analysis framework.
//
// Targets Apple platforms: the engine uses Vision/CoreML for detection,
// AVFoundation for decoding, and Accelerate/simd for math. The C++ `KinematicsCore`
// target is bridged via Swift/C++ interoperability (.interoperabilityMode(.Cxx)).
let package = Package(
    name: "SwingKinematicsEngine",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "SwingKinematicsEngine", targets: ["SwingKinematicsEngine"])
    ],
    targets: [
        // Dependency-free C++ core: covariance-PCA principal axis for club path.
        .target(
            name: "KinematicsCore"
        ),
        // Swift framework. Cxx interop lets it call into KinematicsCore directly.
        .target(
            name: "SwingKinematicsEngine",
            dependencies: ["KinematicsCore"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .testTarget(
            name: "SwingKinematicsEngineTests",
            dependencies: ["SwingKinematicsEngine"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ]
)
