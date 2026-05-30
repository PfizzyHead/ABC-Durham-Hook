//
//  AudioTriggerTests.swift
//  GolfCaptureTests — Phase 1
//
//  Unit tests for the acoustic impact decision. Pure logic — runs in CI on the
//  Simulator/macOS with no microphone. Field calibration of the *threshold
//  values* still requires real impacts, but this pins the gating behaviour.
//

import XCTest
@testable import GolfCapture

final class AudioTriggerTests: XCTestCase {

    private let attack: Float = 6.0
    private let bright: Float = 0.45

    func testFiresOnLoudBrightTransient() {
        // 10× ambient and 70% high-band energy → clear impact.
        XCTAssertTrue(AudioTriggerManager.isImpact(
            rms: 0.10, ambient: 0.01, brightness: 0.70,
            attackRatio: attack, brightnessRatio: bright))
    }

    func testRejectsLoudButDullSound() {
        // Loud (a shout) but low-frequency / dull → not an impact.
        XCTAssertFalse(AudioTriggerManager.isImpact(
            rms: 0.10, ambient: 0.01, brightness: 0.20,
            attackRatio: attack, brightnessRatio: bright))
    }

    func testRejectsBrightButQuietSound() {
        // Bright but barely above the floor (e.g. distant chirp) → not an impact.
        XCTAssertFalse(AudioTriggerManager.isImpact(
            rms: 0.02, ambient: 0.01, brightness: 0.80,
            attackRatio: attack, brightnessRatio: bright))
    }

    func testBoundaryIsInclusiveOnBrightnessExclusiveOnAttack() {
        // brightness exactly at threshold passes; attack must strictly exceed.
        XCTAssertFalse(AudioTriggerManager.isImpact(
            rms: 0.06, ambient: 0.01, brightness: 0.45,   // rms == 6×ambient, not >
            attackRatio: attack, brightnessRatio: bright))
        XCTAssertTrue(AudioTriggerManager.isImpact(
            rms: 0.0601, ambient: 0.01, brightness: 0.45,
            attackRatio: attack, brightnessRatio: bright))
    }
}
