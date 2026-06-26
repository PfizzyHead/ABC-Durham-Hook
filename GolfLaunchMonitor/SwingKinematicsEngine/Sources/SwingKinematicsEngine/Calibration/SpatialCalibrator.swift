// SpatialCalibrator.swift
//
// Converts the known physical size of a regulation golf ball into a precise
// mm-per-pixel scaling factor at the ball's depth plane, and (given camera
// intrinsics) recovers the ball's distance from the lens via the pinhole model.

import Foundation
import simd

/// Pinhole camera intrinsics, in pixel units. `focalLengthPixels` is fx (and is
/// assumed ≈ fy for square pixels). On iOS these come from
/// `AVCameraCalibrationData` or `CMSampleBuffer` intrinsic-matrix attachments.
public struct CameraIntrinsics: Sendable {
    /// Focal length along x, in pixels.
    public let focalLengthPixels: Double
    /// Principal point (optical center), in pixels. Optional; unused for scale
    /// but retained for downstream back-projection.
    public let principalPoint: SIMD2<Double>?

    public init(focalLengthPixels: Double, principalPoint: SIMD2<Double>? = nil) {
        self.focalLengthPixels = focalLengthPixels
        self.principalPoint = principalPoint
    }
}

/// The result of a spatial calibration pass.
public struct SpatialCalibration: Sendable {
    /// Millimeters of real-world distance represented by one pixel at the ball's
    /// depth plane. This is the master scale factor consumed by every kinematic
    /// calculation.
    public let mmPerPixel: Double
    /// The robust (median) ball diameter, in pixels, used to derive the scale.
    public let ballPixelDiameter: Double
    /// Distance from the lens to the ball, in millimeters. Present only when
    /// camera intrinsics were supplied.
    public let distanceFromLensMM: Double?
    /// Number of static-frame samples that contributed to the estimate.
    public let sampleCount: Int

    /// Convert a pixel-space displacement vector to millimeters.
    public func millimeters(fromPixels pixels: SIMD2<Double>) -> SIMD2<Double> {
        pixels * mmPerPixel
    }

    /// Convert a scalar pixel distance to millimeters.
    public func millimeters(fromPixels pixels: Double) -> Double {
        pixels * mmPerPixel
    }
}

public enum CalibrationError: Error, Sendable {
    /// No `ball_static` detections were available to calibrate against.
    case noStaticBallSamples
    /// The detected ball diameter was non-positive (degenerate box).
    case degenerateBallDiameter
}

/// Derives spatial scale from the regulation diameter of a golf ball.
public struct SpatialCalibrator {

    // MARK: Physical constants

    /// Regulation minimum golf-ball diameter (USGA/R&A), in inches.
    public static let regulationBallDiameterInches = 1.68
    /// Millimeters per inch.
    public static let mmPerInch = 25.4
    /// Regulation ball diameter in millimeters (≈ 42.672 mm).
    public static var regulationBallDiameterMM: Double {
        regulationBallDiameterInches * mmPerInch
    }

    /// The physical ball diameter to calibrate against, in millimeters.
    /// Defaults to the regulation value but is injectable for test balls.
    public let ballDiameterMM: Double

    public init(ballDiameterMM: Double = SpatialCalibrator.regulationBallDiameterMM) {
        self.ballDiameterMM = ballDiameterMM
    }

    /// Calibrate from one or more static-ball detections drawn from the initial,
    /// pre-impact frames where the ball is at rest.
    ///
    /// The scale factor is `physicalDiameter / pixelDiameter`. We take the median
    /// pixel diameter across all supplied samples so that a single noisy
    /// detection cannot skew the result. When intrinsics are provided we also
    /// solve the pinhole relation `Z = f · D / d` for the lens-to-ball distance.
    ///
    /// - Parameters:
    ///   - staticBallDetections: `ball_static` detections from the static frames.
    ///   - intrinsics: optional camera intrinsics enabling distance recovery.
    public func calibrate(
        staticBallDetections: [Detection],
        intrinsics: CameraIntrinsics? = nil
    ) throws -> SpatialCalibration {
        let diameters = staticBallDetections
            .filter { $0.label == .ballStatic }
            .map { $0.box.pixelDiameter }
            .filter { $0 > 0 }

        guard !diameters.isEmpty else {
            // Fall back to any positive-diameter sample regardless of label so a
            // caller can still calibrate from a hand-picked box if needed.
            guard let any = staticBallDetections.map({ $0.box.pixelDiameter }).filter({ $0 > 0 }).first else {
                throw CalibrationError.noStaticBallSamples
            }
            return try calibration(pixelDiameter: any, sampleCount: 1, intrinsics: intrinsics)
        }

        let medianDiameter = SpatialCalibrator.median(diameters)
        return try calibration(
            pixelDiameter: medianDiameter,
            sampleCount: diameters.count,
            intrinsics: intrinsics
        )
    }

    private func calibration(
        pixelDiameter: Double,
        sampleCount: Int,
        intrinsics: CameraIntrinsics?
    ) throws -> SpatialCalibration {
        guard pixelDiameter > 0 else { throw CalibrationError.degenerateBallDiameter }

        let mmPerPixel = ballDiameterMM / pixelDiameter

        var distanceMM: Double?
        if let intrinsics {
            // Pinhole similar-triangles: image_diameter / focal = real_diameter / Z
            // => Z = focal · real_diameter / image_diameter.
            distanceMM = intrinsics.focalLengthPixels * ballDiameterMM / pixelDiameter
        }

        return SpatialCalibration(
            mmPerPixel: mmPerPixel,
            ballPixelDiameter: pixelDiameter,
            distanceFromLensMM: distanceMM,
            sampleCount: sampleCount
        )
    }

    /// Median of a non-empty array. Used for outlier-robust diameter estimation.
    static func median(_ values: [Double]) -> Double {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }
}
