// SwingKinematicsEngine.swift
//
// Top-level orchestrator. Ingests the Phase-1 MP4, runs per-frame detection,
// locates impact, calibrates spatial scale from the static ball, and emits the
// kinematic metrics. The pure `analyze(frames:)` entry point runs the entire
// math pipeline on pre-collected detections, so the kinematics are unit-testable
// with no video decoding or model dependency.

import Foundation
import simd

/// Tunable parameters for one analysis run.
public struct EngineConfiguration: Sendable {
    /// Physical ball diameter for calibration (default: regulation 42.672 mm).
    public var ballDiameterMM: Double
    /// Number of post-impact frames used for ball speed.
    public var ballSpeedWindow: Int
    /// Number of pre-impact frames used for club path.
    public var clubPathWindow: Int
    /// Optional camera intrinsics enabling lens-distance recovery.
    public var intrinsics: CameraIntrinsics?
    /// Back-projector for club path (vertical-plane attack angle by default).
    public var clubPathBackProjector: WorldBackProjector
    /// Force a specific impact frame instead of auto-detecting it. Phase 1
    /// captures 1.0 s pre-impact at 240 FPS, so impact is nominally frame 240.
    public var impactFrameOverride: Int?
    /// Minimum confidence for a detection to be trusted in tracking.
    public var trackingConfidenceThreshold: Double

    public init(
        ballDiameterMM: Double = SpatialCalibrator.regulationBallDiameterMM,
        ballSpeedWindow: Int = 5,
        clubPathWindow: Int = 6,
        intrinsics: CameraIntrinsics? = nil,
        clubPathBackProjector: WorldBackProjector = PlanarVerticalBackProjector(),
        impactFrameOverride: Int? = nil,
        trackingConfidenceThreshold: Double = 0.25
    ) {
        self.ballDiameterMM = ballDiameterMM
        self.ballSpeedWindow = ballSpeedWindow
        self.clubPathWindow = clubPathWindow
        self.intrinsics = intrinsics
        self.clubPathBackProjector = clubPathBackProjector
        self.impactFrameOverride = impactFrameOverride
        self.trackingConfidenceThreshold = trackingConfidenceThreshold
    }
}

public enum PipelineError: Error, Sendable {
    /// No `ball_flight` detection was found and no impact override was supplied.
    case impactNotFound
    /// Not enough ball-flight frames after impact to fit a velocity.
    case insufficientBallFlight
    /// Not enough club-head frames before impact to fit a direction.
    case insufficientClubHead
}

/// The offline swing-analysis engine.
public struct SwingKinematicsEngine {

    private let detector: SwingObjectDetector
    public let configuration: EngineConfiguration

    public init(detector: SwingObjectDetector, configuration: EngineConfiguration = EngineConfiguration()) {
        self.detector = detector
        self.configuration = configuration
    }

    // MARK: - Full pipeline (decode -> detect -> analyze)

    /// Run the complete pipeline against a frame provider (e.g. the Phase-1 MP4).
    public func analyze(provider: VideoFrameProvider) async throws -> SwingMetrics {
        var collected: [FrameDetections] = []
        if let count = provider.clipInfo.frameCount {
            collected.reserveCapacity(count)
        }

        for try await frame in provider.frames() {
            let detections = try await detector.detect(in: frame)
            collected.append(
                FrameDetections(index: frame.index, timestamp: frame.timestamp, detections: detections)
            )
        }

        return try analyze(frames: collected)
    }

    // MARK: - Pure analysis (no I/O, fully testable)

    /// Run the math pipeline over already-collected per-frame detections.
    public func analyze(frames: [FrameDetections]) throws -> SwingMetrics {
        let impactIndex = try resolveImpactIndex(frames: frames)

        // --- Spatial calibration from the static ball in the pre-impact frames.
        let staticBalls = frames
            .filter { $0.index < impactIndex }
            .compactMap { $0.best(.ballStatic) }
            .filter { $0.confidence >= configuration.trackingConfidenceThreshold }
        let calibrator = SpatialCalibrator(ballDiameterMM: configuration.ballDiameterMM)
        let calibration = try calibrator.calibrate(
            staticBallDetections: staticBalls,
            intrinsics: configuration.intrinsics
        )

        // --- Ball speed from the post-impact ball-flight track.
        let flightTrack = track(label: .ballFlight, in: frames) { $0.index >= impactIndex }
        guard flightTrack.count >= 2 else { throw PipelineError.insufficientBallFlight }
        let ballSpeed = try BallSpeedCalculator(windowSize: configuration.ballSpeedWindow)
            .ballSpeed(samples: flightTrack, calibration: calibration)

        // --- Launch angle from the velocity vector.
        let launchAngle = LaunchAngleCalculator().launchAngle(from: ballSpeed)

        // --- Club path from the pre-impact club-head track.
        let clubTrack = track(label: .clubHead, in: frames) { $0.index <= impactIndex }
        guard clubTrack.count >= 2 else { throw PipelineError.insufficientClubHead }
        let clubPath = try ClubPathCalculator(
            windowSize: configuration.clubPathWindow,
            backProjector: configuration.clubPathBackProjector
        ).clubPath(samples: clubTrack, calibration: calibration)

        return SwingMetrics(
            calibration: calibration,
            ballSpeed: ballSpeed,
            launchAngle: launchAngle,
            clubPath: clubPath,
            impactFrameIndex: impactIndex
        )
    }

    // MARK: - Helpers

    /// Impact = explicit override, else the first frame containing a confident
    /// `ball_flight` detection.
    private func resolveImpactIndex(frames: [FrameDetections]) throws -> Int {
        if let override = configuration.impactFrameOverride { return override }
        let firstFlight = frames
            .filter { frame in
                (frame.best(.ballFlight)?.confidence ?? 0) >= configuration.trackingConfidenceThreshold
            }
            .min { $0.index < $1.index }
        guard let impact = firstFlight else { throw PipelineError.impactNotFound }
        return impact.index
    }

    /// Build a time-ordered track of one label's best detection per frame,
    /// restricted to frames passing `predicate`.
    private func track(
        label: SwingObjectLabel,
        in frames: [FrameDetections],
        where predicate: (FrameDetections) -> Bool
    ) -> [TrackSample] {
        frames
            .filter(predicate)
            .sorted { $0.index < $1.index }
            .compactMap { frame -> TrackSample? in
                guard let best = frame.best(label),
                      best.confidence >= configuration.trackingConfidenceThreshold else {
                    return nil
                }
                return TrackSample(timestamp: frame.timestamp, imagePoint: best.box.center)
            }
    }
}
