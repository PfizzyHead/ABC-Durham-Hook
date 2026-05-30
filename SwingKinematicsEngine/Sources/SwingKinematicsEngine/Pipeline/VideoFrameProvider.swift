// VideoFrameProvider.swift
//
// Ingests the Phase-1 MP4 (1080p, 240 FPS, 1.0 s pre- + 1.5 s post-impact) and
// emits decoded frames. The protocol keeps the engine decoupled from any
// particular decoder; the AVFoundation implementation is the production path.

import Foundation
import simd

/// Static description of a capture clip.
public struct ClipInfo: Sendable {
    public let frameRate: Double
    public let size: SIMD2<Double>
    public let frameCount: Int?

    public init(frameRate: Double, size: SIMD2<Double>, frameCount: Int?) {
        self.frameRate = frameRate
        self.size = size
        self.frameCount = frameCount
    }
}

/// Supplies frames in capture order, lazily, as an async stream.
public protocol VideoFrameProvider: Sendable {
    /// Metadata available before decoding starts.
    var clipInfo: ClipInfo { get }
    /// Frames in presentation order. Throws on decode failure.
    func frames() -> AsyncThrowingStream<VideoFrame, Error>
}

#if canImport(AVFoundation) && canImport(CoreVideo)
import AVFoundation
import CoreVideo

/// Decodes frames from an MP4 on disk using `AVAssetReader`.
public final class AVAssetReaderFrameProvider: VideoFrameProvider, @unchecked Sendable {

    public let clipInfo: ClipInfo
    private let asset: AVAsset
    private let track: AVAssetTrack

    public init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameProviderError.noVideoTrack
        }
        let frameRate = try await Double(track.load(.nominalFrameRate))
        let naturalSize = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let count = frameRate > 0 ? Int((duration.seconds * frameRate).rounded()) : nil

        self.asset = asset
        self.track = track
        self.clipInfo = ClipInfo(
            frameRate: frameRate,
            size: SIMD2(Double(naturalSize.width), Double(naturalSize.height)),
            frameCount: count
        )
    }

    public func frames() -> AsyncThrowingStream<VideoFrame, Error> {
        AsyncThrowingStream { continuation in
            do {
                let reader = try AVAssetReader(asset: asset)
                // BGRA output is directly consumable by Vision / CoreML.
                let output = AVAssetReaderTrackOutput(
                    track: track,
                    outputSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                )
                output.alwaysCopiesSampleData = false
                reader.add(output)
                guard reader.startReading() else {
                    throw reader.error ?? FrameProviderError.readerFailedToStart
                }

                let size = clipInfo.size
                var index = 0
                while reader.status == .reading,
                      let sample = output.copyNextSampleBuffer() {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let buffer = CMSampleBufferGetImageBuffer(sample)
                    continuation.yield(
                        VideoFrame(
                            index: index,
                            timestamp: pts.seconds.isFinite ? pts.seconds : Double(index) / clipInfo.frameRate,
                            size: size,
                            pixelBuffer: buffer
                        )
                    )
                    index += 1
                }

                if reader.status == .failed {
                    throw reader.error ?? FrameProviderError.decodeFailed
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
#endif

public enum FrameProviderError: Error, Sendable {
    case noVideoTrack
    case readerFailedToStart
    case decodeFailed
}
