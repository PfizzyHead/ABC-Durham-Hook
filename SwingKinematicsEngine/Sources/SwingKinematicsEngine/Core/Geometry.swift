// Geometry.swift
//
// Lightweight value types describing positions and bounding boxes in image
// space. All image coordinates use a top-left origin with +x to the right and
// +y downward (the native convention for CVPixelBuffer / CoreVideo). Helpers are
// provided to convert from Vision's normalized bottom-left coordinate space.

import simd

/// A bounding box expressed in pixel units with a top-left origin.
public struct BoundingBox: Equatable, Sendable {
    /// Left edge, in pixels from the left of the frame.
    public var x: Double
    /// Top edge, in pixels from the top of the frame.
    public var y: Double
    /// Width of the box, in pixels.
    public var width: Double
    /// Height of the box, in pixels.
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Geometric center of the box in pixel space.
    public var center: SIMD2<Double> {
        SIMD2(x + width / 2.0, y + height / 2.0)
    }

    /// Effective pixel radius, averaged across both axes. For a near-circular
    /// object (a golf ball) width and height agree; averaging halves the impact
    /// of detector jitter on either edge.
    public var pixelRadius: Double {
        (width + height) / 4.0
    }

    /// Effective pixel diameter (2 × `pixelRadius`).
    public var pixelDiameter: Double {
        (width + height) / 2.0
    }

    /// Build a pixel-space box from Vision's normalized rect, which uses a
    /// bottom-left origin and 0...1 coordinates relative to the image size.
    ///
    /// - Parameters:
    ///   - normalized: (x, y, width, height) in 0...1, bottom-left origin.
    ///   - imageSize: pixel dimensions of the source frame.
    public static func fromVisionNormalized(
        x nx: Double, y ny: Double, width nw: Double, height nh: Double,
        imageSize: SIMD2<Double>
    ) -> BoundingBox {
        let pxWidth = nw * imageSize.x
        let pxHeight = nh * imageSize.y
        let pxX = nx * imageSize.x
        // Flip the y-axis: Vision's bottom-left origin -> top-left origin.
        let pxY = (1.0 - ny - nh) * imageSize.y
        return BoundingBox(x: pxX, y: pxY, width: pxWidth, height: pxHeight)
    }
}
