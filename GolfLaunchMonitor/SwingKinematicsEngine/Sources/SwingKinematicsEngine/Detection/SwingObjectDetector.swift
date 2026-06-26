// SwingObjectDetector.swift
//
// Protocol scaffolding for plugging a YOLOv8-nano / CoreML object-detection
// model into the pipeline. The engine depends only on these abstractions, so
// the concrete model (CoreML, a remote service, or a fixture for tests) can be
// swapped without touching the kinematics layer.

import Foundation
import simd

#if canImport(CoreVideo)
import CoreVideo
#endif

/// A single decoded video frame handed to a detector.
///
/// The pixel buffer is optional so that test fixtures and replay providers can
/// drive the pipeline with pre-computed detections (see `ScriptedDetector`)
/// without owning real image data.
public struct VideoFrame: @unchecked Sendable {
    /// Zero-based index within the clip.
    public let index: Int
    /// Presentation timestamp in seconds from clip start.
    public let timestamp: TimeInterval
    /// Pixel dimensions of the frame.
    public let size: SIMD2<Double>
    #if canImport(CoreVideo)
    /// The decoded image data, when available.
    public let pixelBuffer: CVPixelBuffer?
    #endif

    #if canImport(CoreVideo)
    public init(index: Int, timestamp: TimeInterval, size: SIMD2<Double>, pixelBuffer: CVPixelBuffer?) {
        self.index = index
        self.timestamp = timestamp
        self.size = size
        self.pixelBuffer = pixelBuffer
    }
    #else
    public init(index: Int, timestamp: TimeInterval, size: SIMD2<Double>) {
        self.index = index
        self.timestamp = timestamp
        self.size = size
    }
    #endif
}

/// Abstraction over any model that maps a frame to bounding-box detections.
///
/// Implementations must be safe to call concurrently or document otherwise; the
/// pipeline may pipeline frames through a detection actor.
public protocol SwingObjectDetector: Sendable {
    /// Detect `club_head`, `ball_static`, and `ball_flight` in a single frame.
    /// - Returns: zero or more detections, each in pixel-space coordinates.
    func detect(in frame: VideoFrame) async throws -> [Detection]
}

/// A detector backed by pre-scripted per-frame detections. Indispensable for
/// unit-testing the kinematics math in isolation from a real model.
public struct ScriptedDetector: SwingObjectDetector {
    private let script: [Int: [Detection]]

    /// - Parameter script: maps frame index -> detections to return for it.
    public init(script: [Int: [Detection]]) {
        self.script = script
    }

    public func detect(in frame: VideoFrame) async throws -> [Detection] {
        script[frame.index] ?? []
    }
}
