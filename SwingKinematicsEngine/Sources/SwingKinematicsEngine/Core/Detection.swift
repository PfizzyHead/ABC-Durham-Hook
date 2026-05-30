// Detection.swift
//
// The detection vocabulary shared between the object-detection layer and the
// kinematics layer. The three labels mirror the classes the YOLOv8-nano /
// CoreML model is trained to emit.

import Foundation

/// The object classes the swing detector recognizes.
public enum SwingObjectLabel: String, CaseIterable, Sendable {
    /// The club head, tracked through the downswing into impact.
    case clubHead = "club_head"
    /// The ball at rest on the tee/turf, used for spatial calibration and as the
    /// impact reference point.
    case ballStatic = "ball_static"
    /// The ball in flight, tracked across the post-impact window.
    case ballFlight = "ball_flight"
}

/// A single detected object within one frame.
public struct Detection: Sendable {
    /// The recognized class.
    public let label: SwingObjectLabel
    /// Model confidence in 0...1.
    public let confidence: Double
    /// Bounding box in pixel space (top-left origin).
    public let box: BoundingBox

    public init(label: SwingObjectLabel, confidence: Double, box: BoundingBox) {
        self.label = label
        self.confidence = confidence
        self.box = box
    }
}

/// All detections recovered from a single frame, tagged with its position in the
/// capture timeline.
public struct FrameDetections: Sendable {
    /// Zero-based frame index within the clip.
    public let index: Int
    /// Presentation timestamp of the frame, in seconds from clip start.
    public let timestamp: TimeInterval
    /// Every object detected in this frame.
    public let detections: [Detection]

    public init(index: Int, timestamp: TimeInterval, detections: [Detection]) {
        self.index = index
        self.timestamp = timestamp
        self.detections = detections
    }

    /// The highest-confidence detection of a given label in this frame, if any.
    public func best(_ label: SwingObjectLabel) -> Detection? {
        detections
            .filter { $0.label == label }
            .max { $0.confidence < $1.confidence }
    }
}
