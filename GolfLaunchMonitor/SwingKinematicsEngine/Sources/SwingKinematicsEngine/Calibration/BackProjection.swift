// BackProjection.swift
//
// Maps 2-D image points into 3-D world coordinates so the kinematics layer can
// reason in physical units. The world frame is right-handed:
//
//     +X = downrange (toward the target)
//     +Y = lateral   (right of the target line, looking downrange)
//     +Z = vertical  (up, against gravity)
//
// A single camera observes only one plane, so each back-projector recovers the
// axes its geometry actually supports. Fusing lateral + vertical into a true 3-D
// measurement requires two views (e.g. down-the-line + overhead); the protocol
// lets such a fused projector drop in without changing the math above it.

import Foundation
import simd

/// Converts an image-space point (pixels, top-left origin) into a world point
/// in millimeters using a calibration.
public protocol WorldBackProjector: Sendable {
    func worldPoint(imagePoint: SIMD2<Double>, calibration: SpatialCalibration) -> SIMD3<Double>
}

/// Side-on / down-the-line camera: recovers the vertical (downrange × up) plane.
///
/// Image +x maps to downrange and image +y (which points *down*) maps to −Z so
/// that up is positive. The lateral axis is unobservable from this view and is
/// fixed at 0 — which makes the recovered club-path direction an *attack-angle*
/// estimate in the vertical plane, and leaves face-angle to an overhead view.
public struct PlanarVerticalBackProjector: WorldBackProjector {
    public init() {}

    public func worldPoint(imagePoint p: SIMD2<Double>, calibration: SpatialCalibration) -> SIMD3<Double> {
        let s = calibration.mmPerPixel
        return SIMD3(p.x * s, 0.0, -p.y * s)
    }
}

/// Overhead camera: recovers the ground (downrange × lateral) plane via a planar
/// homography mapping image pixels to world millimeters on the turf (Z = 0).
///
/// This is the view that yields a genuine *club path* face angle (in-to-out /
/// out-to-in). Supply the 3×3 homography from a one-time court/mat calibration.
public struct GroundPlaneHomographyBackProjector: WorldBackProjector {
    /// Homography H mapping homogeneous image pixels to world-mm ground points.
    public let homography: simd_double3x3

    public init(homography: simd_double3x3) {
        self.homography = homography
    }

    public func worldPoint(imagePoint p: SIMD2<Double>, calibration: SpatialCalibration) -> SIMD3<Double> {
        let h = homography * SIMD3(p.x, p.y, 1.0)
        guard abs(h.z) > 1e-9 else { return SIMD3(0, 0, 0) }
        return SIMD3(h.x / h.z, h.y / h.z, 0.0) // (downrange, lateral, ground)
    }
}
