// LaunchAngle.swift
//
// Launch angle: the vertical departure angle of the ball relative to the
// horizontal ground plane, derived from the post-impact velocity vector.

import Foundation
import simd

public struct LaunchAngleResult: Sendable {
    /// Launch angle in degrees. Positive = above horizontal (the normal case).
    public let degrees: Double
    /// Launch angle in radians.
    public let radians: Double
}

public struct LaunchAngleCalculator {

    public init() {}

    /// Launch angle from a vertical-plane velocity vector (downrange, up) in any
    /// consistent units (mm/s recommended, straight from `BallSpeedResult`).
    ///
    /// θ = atan2(v_up, |v_downrange|). Using the magnitude of the downrange
    /// component makes the angle independent of swing direction (left- or
    /// right-handed, camera on either side), while the signed vertical component
    /// preserves a (rare) negative launch.
    public func launchAngle(velocity: SIMD2<Double>) -> LaunchAngleResult {
        let downrange = abs(velocity.x)
        let up = velocity.y
        let radians = atan2(up, downrange)
        return LaunchAngleResult(degrees: radians * 180.0 / .pi, radians: radians)
    }

    /// Convenience: launch angle straight from a ball-speed result.
    public func launchAngle(from speed: BallSpeedResult) -> LaunchAngleResult {
        launchAngle(velocity: speed.velocityMMPerSecond)
    }
}
