//
//  PCMSink.swift
//  Spotty
//
//  The decode pipeline's output seam. `AudioRenderer` is the one production conformer; checks use
//  a fake so the pipeline's threading and pacing can be exercised without AVFoundation.
//

/// Outcome of one `PCMSink.write` call.
enum PCMWriteOutcome: Equatable, Sendable {
    /// All the frames were queued -- `write` may still have blocked on backpressure to get there.
    case queued
    /// `write` returned before every frame was queued, either because `cancelled()` reported true
    /// or the sink stopped accepting audio out from under a parked writer. The caller must not
    /// count these frames as delivered.
    case cancelled
}

/// Where `VorbisDecodePipeline` delivers decoded interleaved stereo Float32 samples.
///
/// Thread safety: every method may be called from the pipeline's dedicated decode thread, never
/// from the main actor. `Sendable` is required here because the pipeline hands a `PCMSink`
/// straight into the `@Sendable` closure that seeds its dedicated `Thread` -- a conformer must
/// synchronize its own state internally (`AudioRenderer` already does, under `bufferLock`) rather
/// than rely on the compiler to catch cross-thread misuse.
protocol PCMSink: AnyObject, Sendable {
    /// Writes `frames` interleaved stereo Float32 frames, blocking on backpressure until they are
    /// all queued or `cancelled()` reports true. `cancelled` is polled between bounded waits, not
    /// just once, so a caller that wants this to return promptly should keep it cheap.
    func write(_ samples: UnsafePointer<Float>, frames: Int, until cancelled: () -> Bool) -> PCMWriteOutcome

    /// Discards whatever is currently buffered, e.g. after a seek.
    func flush()

    /// Seconds of audio still queued for playback. The pipeline polls this to hold `.endOfTrack`
    /// until playout has actually drained, not merely until decoding is done.
    var bufferedSeconds: Double { get }
}

extension AudioRenderer: PCMSink {}
