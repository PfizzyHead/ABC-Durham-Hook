//
//  FrameRingBuffer.swift
//  GolfCapture — Phase 1: High-Speed Data Capture Engine
//
//  A fixed-capacity, thread-safe FIFO ring buffer that holds the most recent
//  ~3 seconds of *compressed* video at 240 FPS (720 slots).
//
//  ──────────────────────────────────────────────────────────────────────────
//  MEMORY FOOTPRINT — WHY WE STORE COMPRESSED SAMPLES, NOT RAW PIXELS
//  ──────────────────────────────────────────────────────────────────────────
//  A single 1080p frame is large:
//      • BGRA (4 B/px):   1920 × 1080 × 4   ≈ 8.3 MB / frame
//      • NV12 (1.5 B/px): 1920 × 1080 × 1.5 ≈ 3.1 MB / frame
//
//  720 raw BGRA frames ≈ 6.0 GB, and 720 NV12 frames ≈ 2.2 GB. Both numbers are
//  far above the per-app jetsam limit on any iPhone — the OS would terminate the
//  app instantly, and continuously touching that much memory at 240 Hz would
//  thrash the allocator and overheat the device.
//
//  Instead, frames are H.264/HEVC-encoded *before* they enter this buffer (see
//  VideoEncoder). A compressed 1080p inter-frame is typically 5–40 KB, so 3 s of
//  footage lives in roughly 10–40 MB of RAM — two orders of magnitude smaller,
//  with no continuous disk I/O.
//
//  LEAK / RETENTION DISCIPLINE
//  • `CMSampleBuffer` is an ARC-managed Swift class. When a slot is overwritten
//    (eviction) the old reference is dropped and Core Media frees the backing
//    `CMBlockBuffer` immediately — no manual CFRelease, no unbounded growth.
//  • The buffer is bounded *by construction*: it can never hold more than
//    `capacity` references, so steady-state memory is flat regardless of how
//    long the session runs.
//  • All mutation happens behind a single serial lock; the capture/encode
//    callback never blocks on the (rare) export read path.
//

import Foundation
import CoreMedia

/// One encoded frame plus the metadata the exporter needs to slice the timeline.
struct EncodedFrame {
    /// Compressed (H.264/HEVC) sample. Owns its `CMBlockBuffer`; freed on eviction.
    let sample: CMSampleBuffer
    /// Presentation timestamp on the capture clock — the slicing key.
    let pts: CMTime
    /// True for IDR/key frames. A decodable clip must start on a key frame.
    let isKeyframe: Bool
}

/// Fixed-capacity FIFO. Newest frame overwrites the oldest once full (pre-roll).
final class FrameRingBuffer {

    /// 720 slots = 3.0 s at 240 FPS.
    let capacity: Int

    private var storage: [EncodedFrame?]
    private var head = 0          // index of the next write
    private var count = 0         // number of live frames (<= capacity)
    private let lock = NSLock()   // cheap, uncontended on the hot path

    init(capacity: Int = 720) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    /// Append one encoded frame. O(1). Evicts (and frees) the oldest when full.
    func append(_ frame: EncodedFrame) {
        lock.lock()
        defer { lock.unlock() }
        // Overwriting drops the previous reference at this slot → Core Media
        // releases that frame's backing store right here. Memory stays flat.
        storage[head] = frame
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// Snapshot every live frame in chronological (oldest → newest) order.
    /// Returns *references* (cheap); it does not copy pixel data.
    func snapshot() -> [EncodedFrame] {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return [] }
        var out = [EncodedFrame]()
        out.reserveCapacity(count)
        let start = (head - count + capacity) % capacity
        for i in 0..<count {
            if let f = storage[(start + i) % capacity] { out.append(f) }
        }
        return out
    }

    /// Frames whose PTS falls in [start, end], beginning at the nearest key
    /// frame at or before `start` so the resulting clip is independently
    /// decodable. Used by ClipExporter to carve the pre/post-impact window.
    func frames(in start: CMTime, _ end: CMTime) -> [EncodedFrame] {
        let all = snapshot()
        // Walk back to the last key frame at or before the window start.
        var keyIndex = 0
        for (i, f) in all.enumerated() {
            if f.pts <= start && f.isKeyframe { keyIndex = i }
            if f.pts > end { break }
        }
        return all[keyIndex...].prefix { $0.pts <= end }.map { $0 }
    }

    /// Drop all references (e.g. between sessions). Frees every backing buffer.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        for i in storage.indices { storage[i] = nil }
        head = 0
        count = 0
    }
}
