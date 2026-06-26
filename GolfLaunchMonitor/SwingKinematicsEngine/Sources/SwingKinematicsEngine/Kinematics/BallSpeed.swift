// BallSpeed.swift
//
// Ball-speed estimation from the post-impact ball-flight track.

import Foundation
import simd

/// A single tracked point: a detection center sampled at a known time.
public struct TrackSample: Sendable {
    public let timestamp: TimeInterval
    public let imagePoint: SIMD2<Double>

    public init(timestamp: TimeInterval, imagePoint: SIMD2<Double>) {
        self.timestamp = timestamp
        self.imagePoint = imagePoint
    }
}

/// Ball speed plus the underlying velocity vector.
public struct BallSpeedResult: Sendable {
    /// Velocity in the vertical plane, mm/s, as (downrange, vertical-up).
    public let velocityMMPerSecond: SIMD2<Double>
    /// Scalar speed in meters per second.
    public let metersPerSecond: Double
    /// Scalar speed in miles per hour (the figure golfers expect).
    public let milesPerHour: Double
    /// Number of post-impact samples used in the fit.
    public let sampleCount: Int
}

public enum KinematicsError: Error, Sendable {
    case insufficientSamples(needed: Int, found: Int)
}

/// Computes ball speed from the first frames of flight.
public struct BallSpeedCalculator {

    /// m/s → mph.
    public static let mphPerMeterPerSecond = 2.236_936_292_054_4

    /// Number of post-impact frames to fit by default (the prompt's "first 5").
    public let windowSize: Int

    public init(windowSize: Int = 5) {
        self.windowSize = windowSize
    }

    /// Estimate ball speed from ball-flight track samples.
    ///
    /// Each sample's pixel position is converted to millimeters in the vertical
    /// plane (downrange, up) via the calibration scale. A least-squares slope of
    /// position-vs-time per axis yields the velocity components; the speed is the
    /// magnitude. Fitting over the window (not a single frame pair) suppresses
    /// detector jitter.
    ///
    /// - Parameters:
    ///   - samples: ball-flight samples ordered by time; the first `windowSize`
    ///     are used.
    ///   - calibration: spatial scale from `SpatialCalibrator`.
    public func ballSpeed(
        samples: [TrackSample],
        calibration: SpatialCalibration
    ) throws -> BallSpeedResult {
        let window = Array(samples.prefix(windowSize))
        guard window.count >= 2 else {
            throw KinematicsError.insufficientSamples(needed: 2, found: window.count)
        }

        let times = window.map { $0.timestamp }
        // Convert to world millimeters: +x downrange, +z up (image y points down).
        let downrange = window.map { $0.imagePoint.x * calibration.mmPerPixel }
        let vertical = window.map { -$0.imagePoint.y * calibration.mmPerPixel }

        let vx = LinearRegression.slope(times: times, values: downrange)   // mm/s
        let vz = LinearRegression.slope(times: times, values: vertical)    // mm/s
        let velocity = SIMD2(vx, vz)

        let mmPerSecond = simd.length(velocity)
        let metersPerSecond = mmPerSecond / 1000.0
        let mph = metersPerSecond * Self.mphPerMeterPerSecond

        return BallSpeedResult(
            velocityMMPerSecond: velocity,
            metersPerSecond: metersPerSecond,
            milesPerHour: mph,
            sampleCount: window.count
        )
    }
}
