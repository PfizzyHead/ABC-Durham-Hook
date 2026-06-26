// SwingMetrics.swift
//
// The aggregate output of one offline swing analysis.

import Foundation

/// Everything the engine derives from a single capture.
public struct SwingMetrics: Sendable {
    /// Spatial calibration used for every measurement below.
    public let calibration: SpatialCalibration
    /// Ball speed and its velocity vector.
    public let ballSpeed: BallSpeedResult
    /// Vertical launch angle.
    public let launchAngle: LaunchAngleResult
    /// 3-D club-path direction and its derived angles.
    public let clubPath: ClubPathResult
    /// Frame index identified as impact (first ball-flight frame).
    public let impactFrameIndex: Int

    public init(
        calibration: SpatialCalibration,
        ballSpeed: BallSpeedResult,
        launchAngle: LaunchAngleResult,
        clubPath: ClubPathResult,
        impactFrameIndex: Int
    ) {
        self.calibration = calibration
        self.ballSpeed = ballSpeed
        self.launchAngle = launchAngle
        self.clubPath = clubPath
        self.impactFrameIndex = impactFrameIndex
    }
}
