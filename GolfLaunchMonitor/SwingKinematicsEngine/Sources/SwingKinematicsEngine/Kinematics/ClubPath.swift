// ClubPath.swift
//
// Club-path vector: the 3-D direction the club head is travelling in the frames
// immediately before it reaches the static ball. The direction is the dominant
// principal axis (PCA) of the back-projected club-head centers, computed in the
// C++ core (`skc.principalDirection3`).

import Foundation
import simd
import KinematicsCore

public struct ClubPathResult: Sendable {
    /// Unit travel direction in world space (downrange, lateral, up).
    public let direction: SIMD3<Double>
    /// In-plane path angle on the ground, degrees. Positive = in-to-out
    /// (rightward of the target line, looking downrange). Requires an overhead /
    /// ground-plane back-projector to be non-zero.
    public let horizontalAngleDegrees: Double
    /// Vertical attack angle, degrees. Negative = descending blow (down on the
    /// ball), positive = ascending. Requires a vertical-plane back-projector.
    public let attackAngleDegrees: Double
    /// Number of club-head samples used in the fit.
    public let sampleCount: Int
}

public struct ClubPathCalculator {

    /// Number of pre-impact club-head frames to fit by default.
    public let windowSize: Int
    public let backProjector: WorldBackProjector

    /// - Parameters:
    ///   - windowSize: how many pre-impact club-head samples to use.
    ///   - backProjector: maps image points to world mm. Defaults to the
    ///     side-on vertical-plane projector (yields attack angle).
    public init(windowSize: Int = 6, backProjector: WorldBackProjector = PlanarVerticalBackProjector()) {
        self.windowSize = windowSize
        self.backProjector = backProjector
    }

    /// Compute the club path from club-head samples leading into the ball.
    ///
    /// - Parameters:
    ///   - samples: club-head centers ordered by time; the **last** `windowSize`
    ///     (those nearest impact) are used.
    ///   - calibration: spatial scale from `SpatialCalibrator`.
    public func clubPath(
        samples: [TrackSample],
        calibration: SpatialCalibration
    ) throws -> ClubPathResult {
        let window = Array(samples.suffix(windowSize))
        guard window.count >= 2 else {
            throw KinematicsError.insufficientSamples(needed: 2, found: window.count)
        }

        // Back-project each center and flatten to [x0,y0,z0, x1,y1,z1, ...].
        var flat = [Double]()
        flat.reserveCapacity(window.count * 3)
        for sample in window {
            let w = backProjector.worldPoint(imagePoint: sample.imagePoint, calibration: calibration)
            flat.append(w.x); flat.append(w.y); flat.append(w.z)
        }

        let v = flat.withUnsafeBufferPointer { buf -> skc.Vec3 in
            skc.principalDirection3(buf.baseAddress, numericCast(window.count))
        }
        let direction = SIMD3(v.x, v.y, v.z)

        let horizontal = atan2(direction.y, direction.x) * 180.0 / .pi
        let groundSpeed = sqrt(direction.x * direction.x + direction.y * direction.y)
        let attack = atan2(direction.z, groundSpeed) * 180.0 / .pi

        return ClubPathResult(
            direction: direction,
            horizontalAngleDegrees: horizontal,
            attackAngleDegrees: attack,
            sampleCount: window.count
        )
    }
}
