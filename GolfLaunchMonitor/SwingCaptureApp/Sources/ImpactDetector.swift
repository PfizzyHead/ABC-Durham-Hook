import AVFoundation
import Accelerate

/// Detects the moment of impact from the audio "click" of the strike.
///
/// Computes a per-buffer peak/RMS amplitude and fires when it crosses a
/// threshold, with a refractory period so a single strike triggers once. The
/// threshold is intentionally exposed — it needs on-device tuning against real
/// strike audio vs. ambient range noise.
final class ImpactDetector {

    /// Normalized amplitude (0...1) above which a sample counts as impact.
    var threshold: Float = 0.35
    /// Minimum seconds between triggers.
    var refractory: Double = 1.0

    /// Called (on the sample queue) when impact is detected while enabled.
    var onImpact: (() -> Void)?

    private var enabled = false
    private var lastTrigger: Double = -.greatestFiniteMagnitude

    func enable() { enabled = true; lastTrigger = -.greatestFiniteMagnitude }
    func disable() { enabled = false }

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard enabled else { return }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let data = audioBufferList.mBuffers.mData else { return }

        let count = Int(audioBufferList.mBuffers.mDataByteSize) / MemoryLayout<Int16>.size
        guard count > 0 else { return }

        // Interpret as 16-bit PCM and find the normalized peak magnitude.
        let samples = data.bindMemory(to: Int16.self, capacity: count)
        var peak: Float = 0
        for i in 0..<count {
            let v = abs(Float(samples[i]) / Float(Int16.max))
            if v > peak { peak = v }
        }

        let now = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if peak >= threshold, (now - lastTrigger) >= refractory {
            lastTrigger = now
            onImpact?()
        }
    }
}
