//
//  PCMSink.swift
//  Aural
//
//  The decode pipeline's output seam. `AudioRenderer` is the one production conformer; checks use
//  a fake so the pipeline's threading and pacing can be exercised without AVFoundation.
//

/// Where `VorbisDecodePipeline` delivers decoded interleaved stereo Float32 samples.
///
/// Thread safety: every method may be called from the pipeline's dedicated decode thread, never
/// from the main actor. A conformer must be safe to call from that one background thread; it does
/// not need to be `Sendable` at the type level (`AudioRenderer` already synchronizes internally).
protocol PCMSink: AnyObject {
    /// Writes interleaved stereo Float32 samples. May block the caller on backpressure -- see
    /// `AudioRenderer.writeAudioData`, which is what makes the decode loop self-pacing.
    func write(_ samples: UnsafePointer<Float>, count: Int)

    /// Discards whatever is currently buffered, e.g. after a seek.
    func flush()

    /// Seconds of audio still queued for playback. The pipeline polls this to hold `.endOfTrack`
    /// until playout has actually drained, not merely until decoding is done.
    var bufferedSeconds: Double { get }
}

extension AudioRenderer: PCMSink {
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        writeAudioData(samples, count: count)
    }
}
