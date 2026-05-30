import XCTest
import simd
import SwingKinematicsEngine

final class KinematicsTests: XCTestCase {

    private let fps = 240.0

    /// mmPerPixel = 1.0 when the ball spans exactly its physical diameter in px.
    private func unitCalibration() throws -> SpatialCalibration {
        let px = SpatialCalibrator.regulationBallDiameterMM // 42.672
        let ball = Detection(
            label: .ballStatic,
            confidence: 0.95,
            box: BoundingBox(x: 900, y: 500, width: px, height: px)
        )
        return try SpatialCalibrator().calibrate(staticBallDetections: [ball])
    }

    func testSpatialCalibrationScale() throws {
        let cal = try unitCalibration()
        XCTAssertEqual(cal.mmPerPixel, 1.0, accuracy: 1e-9)
        XCTAssertEqual(cal.ballPixelDiameter, SpatialCalibrator.regulationBallDiameterMM, accuracy: 1e-9)
    }

    func testCalibrationDistanceFromLens() throws {
        // Pinhole: Z = f · D / d. With d = D (px == mm) the distance equals f.
        let px = SpatialCalibrator.regulationBallDiameterMM
        let ball = Detection(label: .ballStatic, confidence: 0.9,
                             box: BoundingBox(x: 0, y: 0, width: px, height: px))
        let cal = try SpatialCalibrator().calibrate(
            staticBallDetections: [ball],
            intrinsics: CameraIntrinsics(focalLengthPixels: 1500)
        )
        XCTAssertEqual(cal.distanceFromLensMM ?? 0, 1500, accuracy: 1e-6)
    }

    func testBallSpeedAndLaunchAngle() throws {
        let cal = try unitCalibration() // mm/px == 1
        let targetMPH = 150.0
        let targetDeg = 20.0
        let speedMPS = targetMPH / BallSpeedCalculator.mphPerMeterPerSecond
        let theta = targetDeg * .pi / 180.0

        // World velocity (mm/s): downrange and up.
        let vxMM = cos(theta) * speedMPS * 1000.0
        let vUpMM = sin(theta) * speedMPS * 1000.0
        // Image velocity (px/s) at scale 1: y points down, so up -> negative dy.
        let dt = 1.0 / fps
        var samples: [TrackSample] = []
        for i in 0..<5 {
            let t = Double(i) * dt
            let x = 500.0 + vxMM * t
            let y = 500.0 - vUpMM * t
            samples.append(TrackSample(timestamp: t, imagePoint: SIMD2(x, y)))
        }

        let speed = try BallSpeedCalculator().ballSpeed(samples: samples, calibration: cal)
        XCTAssertEqual(speed.milesPerHour, targetMPH, accuracy: 0.25)

        let launch = LaunchAngleCalculator().launchAngle(from: speed)
        XCTAssertEqual(launch.degrees, targetDeg, accuracy: 0.05)
    }

    func testClubPathAttackAngleViaCxxPCA() throws {
        let cal = try unitCalibration()
        let attackDeg = -4.0 // descending blow
        let a = attackDeg * .pi / 180.0
        let dt = 1.0 / fps

        // Build world points along (cos a, 0, sin a), then invert to image space:
        // imageX = worldX/scale, imageY = -worldZ/scale.
        var samples: [TrackSample] = []
        for i in 0..<6 {
            let s = Double(i) * 10.0
            let wx = cos(a) * s
            let wz = sin(a) * s
            samples.append(TrackSample(timestamp: Double(i) * dt, imagePoint: SIMD2(wx, -wz)))
        }

        let path = try ClubPathCalculator().clubPath(samples: samples, calibration: cal)
        XCTAssertEqual(path.attackAngleDegrees, attackDeg, accuracy: 0.25)
        // Side-on projector cannot see lateral motion -> path angle is ~0.
        XCTAssertEqual(path.horizontalAngleDegrees, 0, accuracy: 1e-6)
        XCTAssertEqual(simd.length(path.direction), 1.0, accuracy: 1e-9)
    }

    func testEndToEndPureAnalysis() throws {
        let cal = try unitCalibration()
        _ = cal
        let px = SpatialCalibrator.regulationBallDiameterMM
        let dt = 1.0 / fps
        let impact = 5

        let speedMPS = 150.0 / BallSpeedCalculator.mphPerMeterPerSecond
        let theta = 20.0 * .pi / 180.0
        let vxMM = cos(theta) * speedMPS * 1000.0
        let vUpMM = sin(theta) * speedMPS * 1000.0

        var frames: [FrameDetections] = []
        for index in 0..<11 {
            let t = Double(index) * dt
            var dets: [Detection] = []
            if index < impact {
                // Static ball for calibration + an approaching club head.
                dets.append(Detection(label: .ballStatic, confidence: 0.9,
                                      box: BoundingBox(x: 900, y: 500, width: px, height: px)))
                let s = Double(index) * 10.0
                dets.append(Detection(label: .clubHead, confidence: 0.8,
                                      box: BoundingBox(x: 800 + s, y: 500, width: 30, height: 30)))
            } else {
                let tt = Double(index - impact) * dt
                let x = 900.0 + vxMM * tt
                let y = 500.0 - vUpMM * tt
                dets.append(Detection(label: .ballFlight, confidence: 0.85,
                                      box: BoundingBox(x: x, y: y, width: px, height: px)))
            }
            frames.append(FrameDetections(index: index, timestamp: t, detections: dets))
        }

        let engine = SwingKinematicsEngine(detector: ScriptedDetector(script: [:]))
        let metrics = try engine.analyze(frames: frames)

        XCTAssertEqual(metrics.impactFrameIndex, impact)
        XCTAssertEqual(metrics.calibration.mmPerPixel, 1.0, accuracy: 1e-9)
        XCTAssertEqual(metrics.ballSpeed.milesPerHour, 150, accuracy: 0.5)
        XCTAssertEqual(metrics.launchAngle.degrees, 20, accuracy: 0.1)
    }
}
