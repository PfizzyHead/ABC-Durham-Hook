//
//  ClipExporter.swift
//  GolfCapture — Phase 1: High-Speed Data Capture Engine
//
//  Carves the impact window (1.0 s pre + 1.5 s post) out of the in-memory ring
//  buffer and writes ONLY those frames to a persistent .mp4 — the single disk
//  write per swing. Re-timed to start at zero so downstream CV/playback is clean.
//
//  ──────────────────────────────────────────────────────────────────────────
//  WHY THIS IS THE ONLY DISK I/O
//  ──────────────────────────────────────────────────────────────────────────
//  We never write continuously (that overheats the device and burns storage).
//  The compressed frames already live in RAM; here we append the relevant slice
//  to an AVAssetWriter. Because the encoder forces a short GOP, the slice begins
//  on a key frame and is independently decodable.
//
//  MEMORY: the writer streams samples out and we never copy pixel data — the
//  slice is an array of existing CMSampleBuffer references, released as soon as
//  the export completes.
//

import Foundation
import AVFoundation

final class ClipExporter {

    /// Export the given chronological, key-frame-aligned frames to `url`.
    /// `frames` must be ordered by PTS and start on a key frame.
    func export(frames: [EncodedFrame],
                to url: URL,
                completion: @escaping (Result<URL, Error>) -> Void) {
        guard let first = frames.first,
              let formatDesc = CMSampleBufferGetFormatDescription(first.sample) else {
            completion(.failure(ExportError.empty)); return
        }
        try? FileManager.default.removeItem(at: url)

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video,
                                           outputSettings: nil,         // pass-through (already H.264)
                                           sourceFormatHint: formatDesc)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { completion(.failure(ExportError.cannotAddInput)); return }
            writer.add(input)

            // Re-base the timeline so the clip starts at t=0.
            let startPTS = first.pts
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            let queue = DispatchQueue(label: "golf.export")
            var index = 0
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard index < frames.count else {
                        input.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed { completion(.success(url)) }
                            else { completion(.failure(writer.error ?? ExportError.unknown)) }
                        }
                        return
                    }
                    let frame = frames[index]; index += 1
                    if let retimed = Self.retime(frame.sample, by: startPTS) {
                        input.append(retimed)
                    }
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    /// Shift a sample's PTS so the first frame lands at zero.
    private static func retime(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: .init(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in 0..<timings.count {
            timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: sample,
                                              sampleTimingEntryCount: count,
                                              sampleTimingArray: &timings,
                                              sampleBufferOut: &out)
        return out
    }

    enum ExportError: Error { case empty, cannotAddInput, unknown }
}
