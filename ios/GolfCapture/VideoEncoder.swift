//
//  VideoEncoder.swift
//  GolfCapture — Phase 1: High-Speed Data Capture Engine
//
//  Hardware H.264/HEVC encoder (VideoToolbox) that turns raw capture pixel
//  buffers into compact compressed samples for the ring buffer.
//
//  ──────────────────────────────────────────────────────────────────────────
//  MEMORY / THERMAL NOTES
//  ──────────────────────────────────────────────────────────────────────────
//  • Encoding runs on Apple's dedicated media block, not the CPU/GPU, which is
//    what makes sustained 240 FPS feasible without overheating.
//  • We DO NOT retain the inbound CVPixelBuffer. It belongs to the capture
//    session's pixel-buffer *pool*, which has a small fixed depth. Holding one
//    too long starves the pool and stalls capture ("late frame" drops). We hand
//    it to VTCompressionSession synchronously and let it go.
//  • A short key-frame interval (every `keyframeInterval` frames) keeps the GOP
//    small so the exporter can slice an arbitrary 2.5 s window that always
//    starts on a decodable key frame, at a minor bitrate cost.
//

import Foundation
import VideoToolbox
import CoreMedia

final class VideoEncoder {

    /// Called on the encoder's serial queue with each finished compressed frame.
    var onEncodedFrame: ((EncodedFrame) -> Void)?

    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let keyframeInterval: Int   // frames between forced key frames

    init(width: Int32 = 1920, height: Int32 = 1080, keyframeInterval: Int = 12) {
        self.width = width
        self.height = height
        self.keyframeInterval = keyframeInterval
    }

    func start() throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,         // swap for HEVC if desired
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,                        // use the block API below
            refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw NSError(domain: "VideoEncoder", code: Int(status))
        }
        self.session = session

        // Real-time, low-latency profile: no frame reordering (B-frames), so PTS
        // order == capture order, which keeps ring-buffer slicing trivial.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 240 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// Encode one capture frame. Non-blocking; the result arrives via the
    /// completion handler and is forwarded to `onEncodedFrame`.
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample,
                  CMSampleBufferDataIsReady(sample) else { return }
            let frame = EncodedFrame(sample: sample,
                                     pts: pts,
                                     isKeyframe: Self.isKeyframe(sample))
            self?.onEncodedFrame?(frame)
        }
    }

    func stop() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    deinit { stop() }

    /// A sample is a key frame unless it is explicitly flagged "not sync".
    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        var value: UnsafeRawPointer?
        let present = CFDictionaryGetValueIfPresent(dict, key, &value)
        if present, let value {
            return !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
        }
        return true
    }
}
