//
//  FrameRingBufferTests.swift
//  GolfCaptureTests — Phase 1
//
//  Unit tests for the in-memory ring buffer. These run on the iOS Simulator or
//  macOS (XCTest + CoreMedia) — NO physical device or camera required — so they
//  belong in CI. They cover the two pieces of logic most likely to break a clip:
//  FIFO eviction/ordering, and the keyframe-aligned window slicing.
//
//  Add this file to a test target that links the GolfCapture sources.
//

import XCTest
import CoreMedia
@testable import GolfCapture

final class FrameRingBufferTests: XCTestCase {

    // MARK: - Helpers

    /// Minimal valid CMSampleBuffer (1-byte block buffer, no format). The ring
    /// only reads the `pts`/`isKeyframe` we store on `EncodedFrame`, so the
    /// sample's contents are irrelevant for these tests.
    private func makeSample() -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 1,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 1, flags: 0, blockBufferOut: &blockBuffer)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        return sample!
    }

    /// Frame at `seconds` on a 240-tick timescale, optionally a key frame.
    private func frame(at seconds: Double, key: Bool = false) -> EncodedFrame {
        EncodedFrame(sample: makeSample(),
                     pts: CMTime(seconds: seconds, preferredTimescale: 240),
                     isKeyframe: key)
    }

    private func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 240)
    }

    // MARK: - FIFO / eviction

    func testHoldsUpToCapacity() {
        let ring = FrameRingBuffer(capacity: 4)
        (0..<3).forEach { ring.append(frame(at: Double($0))) }
        XCTAssertEqual(ring.snapshot().count, 3)
    }

    func testEvictsOldestWhenFull() {
        let ring = FrameRingBuffer(capacity: 3)
        (0..<5).forEach { ring.append(frame(at: Double($0))) }   // 0,1,2,3,4
        let pts = ring.snapshot().map { $0.pts.seconds }
        // Oldest two (0,1) evicted; newest three remain, in order.
        XCTAssertEqual(pts, [2, 3, 4])
    }

    func testSnapshotIsChronological() {
        let ring = FrameRingBuffer(capacity: 3)
        // Wrap the head past the end to exercise the modular read.
        (0..<7).forEach { ring.append(frame(at: Double($0))) }   // keep 4,5,6
        XCTAssertEqual(ring.snapshot().map { $0.pts.seconds }, [4, 5, 6])
    }

    func testResetFreesEverything() {
        let ring = FrameRingBuffer(capacity: 3)
        (0..<3).forEach { ring.append(frame(at: Double($0))) }
        ring.reset()
        XCTAssertTrue(ring.snapshot().isEmpty)
    }

    // MARK: - Window slicing (pure index math)

    func testWindowSnapsBackToKeyframe() {
        // Keyframes at 0.0 and 0.5; window starts at 0.3 → must begin at 0.0.
        let timeline = [0.0, 0.25, 0.5, 0.75].map(t)
        let keys     = [true, false, true, false]
        let r = FrameRingBuffer.windowIndices(timeline: timeline, isKeyframe: keys,
                                              start: t(0.3), end: t(0.75))
        XCTAssertEqual(r, 0..<4)   // snapped back to keyframe at index 0
    }

    func testWindowStartsAtLaterKeyframeWhenPossible() {
        // Window starts at 0.6 → nearest keyframe at/under start is index 2 (0.5).
        let timeline = [0.0, 0.25, 0.5, 0.75, 1.0].map(t)
        let keys     = [true, false, true, false, true]
        let r = FrameRingBuffer.windowIndices(timeline: timeline, isKeyframe: keys,
                                              start: t(0.6), end: t(1.0))
        XCTAssertEqual(r, 2..<5)
    }

    func testWindowExcludesFramesAfterEnd() {
        let timeline = [0.0, 0.5, 1.0, 1.5, 2.0].map(t)
        let keys     = [true, true, true, true, true]
        let r = FrameRingBuffer.windowIndices(timeline: timeline, isKeyframe: keys,
                                              start: t(0.5), end: t(1.0))
        XCTAssertEqual(r, 1..<3)   // 0.5 and 1.0 only; 1.5/2.0 excluded
    }

    func testEmptyTimelineYieldsEmptyRange() {
        let r = FrameRingBuffer.windowIndices(timeline: [], isKeyframe: [],
                                              start: t(0), end: t(1))
        XCTAssertEqual(r, 0..<0)
    }

    func testFramesInWindowReturnsKeyframeAlignedSlice() {
        let ring = FrameRingBuffer(capacity: 10)
        ring.append(frame(at: 0.0, key: true))
        ring.append(frame(at: 0.25))
        ring.append(frame(at: 0.5, key: true))
        ring.append(frame(at: 0.75))
        let slice = ring.frames(in: t(0.3), t(0.75))
        // Snaps back to the 0.0 keyframe and includes everything through 0.75.
        XCTAssertEqual(slice.first?.pts.seconds, 0.0)
        XCTAssertEqual(slice.count, 4)
    }
}
