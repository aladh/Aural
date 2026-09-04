//
//  VorbisDecodePipeline.swift
//  Aural
//
//  Stage 1 of #201, slice 2b (#208): drives `OggVorbisDecoder` from a `DecodeByteSource` to a
//  `PCMSink` on a dedicated thread. Not yet wired into playback -- the CDN fetcher, AES-CTR
//  decryptor, and `RustPlaybackEngine` wiring are other slices of #208. Nothing here decides how
//  bytes are fetched or decrypted, or how PCM reaches the speakers; it only paces decode against
//  the sink's backpressure and reports transport-relevant events. Byte-layout knowledge (e.g.
//  where the Ogg stream actually starts in a Spotify file) belongs to that CDN/decrypt adapter,
//  not here -- this type only ever sees the offset it is given.
//
//  Thread safety: `OggVorbisDecoder` requires a single owning thread end to end (see its own file
//  header), so this pipeline spins one dedicated `Thread` per `start()` call. The decode loop
//  (`runDecodeLoop` and everything it calls) is `private static`, taking the decoder, the
//  pending-bytes buffer, and the read cursor as locals of its own call stack -- never stored
//  properties, and never a captured `self` -- so `VorbisDecodePipeline` itself does not need to be
//  `Sendable` to seed `Thread.init(block:)`'s `@Sendable` closure; only the small `DecodeGate` it
//  hands across (state already `NSCondition`-guarded) and the `DecodeByteSource`/`PCMSink`
//  parameters (already `Sendable` themselves) cross that boundary. `pause`/`resume`/`seek`/`stop`
//  are called from whatever thread owns transport control (expected: the main actor) and only
//  ever go through that same gate.
//

import AuralDomain
import Foundation

/// Plumbing failures specific to driving the decoder from a byte source, distinct from
/// `OggVorbisDecoderError` (which is about the Vorbis stream itself).
enum VorbisDecodePipelineError: Error, Sendable {
    /// `openHeaders` never succeeded even after growing the prefix to the cap, or the source ran
    /// out of bytes before a full prefix could be read.
    case headerPrefixExceededLimit
    /// A seek's target byte offset has no real Ogg page within the search cap -- the offset is
    /// past the end of the stream, or not really inside an Ogg stream at all.
    case seekCaptureNotFound
}

/// Drives an `OggVorbisDecoder` from a `DecodeByteSource` to a `PCMSink` on a dedicated thread.
/// See the file header for the ownership and thread-confinement contract.
final class VorbisDecodePipeline {
    /// Decode-to-renderer pipeline events. Delivered on the decode thread (except `.paused`,
    /// `.playing` from `resume()`, and `.stopped`, which the calling thread emits directly); a
    /// caller that touches UI/main-actor state from `events` must hop back itself.
    /// The domain's `AudioPipelineEvent`, not a second enum of its own: `AudioPlaybackSession`
    /// reduces exactly these values, so the two must be one type (#219).
    typealias Event = AudioPipelineEvent

    /// Initial `openHeaders` prefix size; doubled on `.needMoreData` up to `maxHeaderPrefixSize`.
    private static let initialHeaderPrefixSize = 16 * 1_024
    private static let maxHeaderPrefixSize = 1_024 * 1_024

    /// Bytes fetched per read once the stream is open.
    private static let readChunkSize = 64 * 1_024

    /// Cap on how far a post-seek page-boundary search grows past one `readChunkSize` read.
    private static let maxSeekSearchSize = 256 * 1_024

    private static let positionEmitInterval: TimeInterval = 0.2

    /// How long `endOfTrack` waits for the sink to drain what is already buffered, and how often
    /// it polls while waiting.
    private static let drainTimeout: TimeInterval = 3.0
    private static let drainPollInterval: TimeInterval = 0.05
    private static let drainedThresholdSeconds: Double = 0.01

    /// Bound on how long `stop()` joins the decode thread. A read the source never completes
    /// cannot be cancelled out from under the thread, so this is a deadline on `stop()` returning,
    /// not a guarantee the thread has actually exited by then.
    private static let stopJoinTimeout: TimeInterval = 2.0

    private let gate = DecodeGate()

    /// Signaled by the decode thread's closure just before it returns, so `stop()` can join it
    /// with a bound instead of blocking forever.
    private let threadFinished = DispatchSemaphore(value: 0)

    /// Spins the dedicated decode thread. No-op if already started.
    ///
    /// - Parameters:
    ///   - startOffset: byte offset of the first `"OggS"` in `source`.
    ///   - startPositionMs: the position to report alongside the first decoded frame; later
    ///     decoded frames add their own elapsed time on top of this base.
    func start(
        source: DecodeByteSource,
        sink: PCMSink,
        startOffset: Int,
        startPositionMs: UInt32,
        events: @escaping @Sendable (Event) -> Void
    ) {
        guard gate.markStarted(events: events) else { return }

        let decodeGate = gate
        let finished = threadFinished
        let thread = Thread {
            Self.runDecodeLoop(
                source: source,
                sink: sink,
                startOffset: startOffset,
                startPositionMs: startPositionMs,
                gate: decodeGate
            )
            finished.signal()
        }
        thread.name = "aural.decode"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Requests the decode loop park at its next between-frames check. Idempotent. Emits
    /// `.paused` immediately; the next successful PCM write after a `resume()` re-emits
    /// `.playing`, since pausing clears the "already told the caller we're playing" latch.
    func pause() {
        gate.pause()
    }

    /// Releases a paused decode loop and emits `.playing`. Idempotent; a no-op if not paused.
    func resume() {
        gate.resume()
    }

    /// Records a pending seek for the decode loop to pick up between frames. A seek that arrives
    /// while another is still pending replaces it -- only the most recent target matters.
    func seek(toByteOffset byteOffset: Int, positionMs: UInt32) {
        gate.setPendingSeek(byteOffset: byteOffset, positionMs: positionMs)
    }

    /// Cancels the decode loop, wakes it if parked, and joins it within a bound. No-op before
    /// `start()` and on a second call. Emits `.stopped` once the join returns (bound or not);
    /// nothing can be emitted after it, by construction of `DecodeGate.emit`.
    func stop() {
        guard gate.requestStop() else { return }
        _ = threadFinished.wait(timeout: .now() + Self.stopJoinTimeout)
        gate.emit(.stopped)
    }

    // MARK: - Decode thread
    //
    // Everything below is `private static`: no instance state, no captured `self`. `gate` is the
    // only shared, cross-thread object these functions touch, plus the `source`/`sink` seams
    // passed through from `start()`.

    /// Runs end to end on the dedicated decode thread: opens headers, then feeds/decodes/writes
    /// until the source is exhausted and the sink drains, or until failure/cancellation.
    private static func runDecodeLoop(
        source: DecodeByteSource,
        sink: PCMSink,
        startOffset: Int,
        startPositionMs: UInt32,
        gate: DecodeGate
    ) {
        let decoder = OggVorbisDecoder()
        var nextReadOffset: Int
        var pending: Data

        do {
            let (consumed, prefix) = try openHeadersGrowingPrefix(
                source: source,
                startOffset: startOffset,
                decoder: decoder
            )
            nextReadOffset = startOffset + prefix.count
            pending = prefix.dropFirst(consumed)
        } catch {
            gate.emit(.failed(failureReason(for: error)))
            return
        }

        var basePositionMs = startPositionMs
        var decodedFrames: Int64 = 0
        var lastPositionEmitUptime: TimeInterval = 0
        var sourceExhausted = false
        var frameBuffer: [Float] = []

        while true {
            guard gate.waitWhilePausedOrCancelled() else { return }

            if let seek = gate.takePendingSeek() {
                sink.flush()
                decoder.flush()
                do {
                    nextReadOffset = try resyncOffsetAfterSeek(seek.byteOffset, source: source)
                } catch {
                    gate.emit(.failed(failureReason(for: error)))
                    return
                }
                pending.removeAll(keepingCapacity: true)
                sourceExhausted = false
                basePositionMs = seek.positionMs
                decodedFrames = 0
                gate.emit(.seeked(seek.positionMs))
                continue
            }

            if pending.isEmpty {
                if sourceExhausted { break }
                do {
                    let chunk = try source.read(offset: nextReadOffset, length: readChunkSize)
                    nextReadOffset += chunk.count
                    if chunk.isEmpty {
                        sourceExhausted = true
                    } else {
                        pending = chunk
                    }
                } catch {
                    gate.emit(.failed(failureReason(for: error)))
                    return
                }
                continue
            }

            let result: (consumed: Int, frames: Int)
            do {
                result = try pending.withUnsafeBytes { try decoder.decodeFrame($0, into: &frameBuffer) }
            } catch {
                gate.emit(.failed(failureReason(for: error)))
                return
            }

            if result.consumed == 0, result.frames == 0 {
                if sourceExhausted { break }
                do {
                    let chunk = try source.read(offset: nextReadOffset, length: readChunkSize)
                    nextReadOffset += chunk.count
                    if chunk.isEmpty {
                        sourceExhausted = true
                    } else {
                        pending.append(chunk)
                    }
                } catch {
                    gate.emit(.failed(failureReason(for: error)))
                    return
                }
                continue
            }

            pending.removeFirst(result.consumed)
            guard result.frames > 0 else { continue }

            let outcome = frameBuffer.withUnsafeBufferPointer { buffer -> PCMWriteOutcome in
                guard let base = buffer.baseAddress else { return .queued }
                return sink.write(base, frames: result.frames, until: { gate.isCancelledNow() })
            }
            // A cancelled write means the sink is not going to play this out; do not count it,
            // and do not report a position or end-of-track that never actually happened.
            guard outcome == .queued else { return }

            decodedFrames += Int64(result.frames)

            if gate.takePendingPlayingEmission() {
                gate.emit(.playing)
            }

            // A pause that lands mid-write can beat this check to the gate; skip the position
            // report rather than announce progress the caller just asked to freeze.
            if !gate.isPausedNow() {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPositionEmitUptime >= positionEmitInterval {
                    lastPositionEmitUptime = now
                    gate.emit(.position(positionMs(basePositionMs: basePositionMs, decodedFrames: decodedFrames)))
                }
            }
        }

        waitForSinkToDrain(sink, gate: gate)
        guard !gate.isCancelledNow() else { return }
        gate.emit(.endOfTrack)
    }

    /// Grows the fed prefix (pushdata semantics require re-feeding from the start of the file,
    /// not just the new bytes -- see `OggVorbisDecoder.openHeaders`) until headers open or the
    /// cap is hit.
    private static func openHeadersGrowingPrefix(
        source: DecodeByteSource,
        startOffset: Int,
        decoder: OggVorbisDecoder
    ) throws -> (consumed: Int, prefix: Data) {
        var prefixSize = initialHeaderPrefixSize
        while true {
            let prefix = try source.read(offset: startOffset, length: prefixSize)
            do {
                let consumed = try prefix.withUnsafeBytes { try decoder.openHeaders($0) }
                return (consumed, prefix)
            } catch OggVorbisDecoderError.needMoreData {
                let sourceExhausted = prefix.count < prefixSize
                guard !sourceExhausted, prefixSize < maxHeaderPrefixSize else {
                    throw VorbisDecodePipelineError.headerPrefixExceededLimit
                }
                prefixSize = min(prefixSize * 2, maxHeaderPrefixSize)
            }
        }
    }

    /// Finds the real Ogg page at or after `byteOffset` via `OggPageHeader.nextValidPage` (which
    /// skips past a capture pattern that turns out to be a false positive inside packet payload
    /// bytes), growing the search window if one page's worth of bytes is not enough.
    /// `decoder.flush()` (already called by the caller) means stb_vorbis resynchronizes on
    /// whatever page boundary decoding resumes from.
    private static func resyncOffsetAfterSeek(_ byteOffset: Int, source: DecodeByteSource) throws -> Int {
        var searchLength = readChunkSize
        while true {
            let window = try source.read(offset: byteOffset, length: searchLength)
            if let match = OggPageHeader.nextValidPage(in: window, from: 0) {
                return byteOffset + match.offset
            }
            guard window.count == searchLength, searchLength < maxSeekSearchSize else {
                throw VorbisDecodePipelineError.seekCaptureNotFound
            }
            searchLength = min(searchLength * 2, maxSeekSearchSize)
        }
    }

    private static func positionMs(basePositionMs: UInt32, decodedFrames: Int64) -> UInt32 {
        let decodedMs = Double(decodedFrames) / 44.1
        return UInt32(max(0, min(Double(UInt32.max), Double(basePositionMs) + decodedMs)))
    }

    /// Polls `sink.bufferedSeconds` down to ~0 (or the timeout) before `endOfTrack` is emitted, so
    /// Spirc does not advance the track while audio the sink already has is still playing out.
    private static func waitForSinkToDrain(_ sink: PCMSink, gate: DecodeGate) {
        let deadline = ProcessInfo.processInfo.systemUptime + drainTimeout
        while sink.bufferedSeconds > drainedThresholdSeconds {
            if gate.isCancelledNow() || ProcessInfo.processInfo.systemUptime >= deadline { return }
            Thread.sleep(forTimeInterval: drainPollInterval)
        }
    }

    /// Classifies a thrown error into a privacy-safe `AudioPipelineFailure` -- never the error's
    /// own description, which for a CDN-backed source can embed a signed URL.
    private static func failureReason(for error: Error) -> AudioPipelineFailure {
        if let vorbisError = error as? OggVorbisDecoderError {
            if case .unsupportedFormat = vorbisError { return .unsupportedFormat }
            return .decode
        }
        if let pipelineError = error as? VorbisDecodePipelineError {
            switch pipelineError {
            case .headerPrefixExceededLimit: return .headers
            case .seekCaptureNotFound: return .seek
            }
        }
        return .sourceRead
    }
}

/// Owns every field `VorbisDecodePipeline`'s control methods and decode loop share across the two
/// threads involved: pause/cancel/seek requests, the "have we told the caller `.playing` since
/// the last pause/seek" latch, and the "has `.stopped` already gone out" latch that makes
/// `emit(_:)` a no-op for anything after it. `NSCondition` is already `Sendable`, and every other
/// stored field here is either guarded by it or (`events`) written once under it before `start()`
/// spins the thread -- so this type is safe to mark `@unchecked Sendable`, which is what lets
/// `VorbisDecodePipeline.start()` hand it into `Thread.init(block:)`'s `@Sendable` closure.
private final class DecodeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isPaused = false
    private var isCancelled = false
    private var hasStarted = false
    private var hasStoppedCalled = false
    private var hasEmittedStopped = false
    private var pendingSeek: (byteOffset: Int, positionMs: UInt32)?
    private var pendingPlayingEmission = true
    private var events: (@Sendable (VorbisDecodePipeline.Event) -> Void)?

    /// Records the events callback and flips `hasStarted`. Returns false if already started.
    func markStarted(events: @escaping @Sendable (VorbisDecodePipeline.Event) -> Void) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !hasStarted else { return false }
        hasStarted = true
        self.events = events
        return true
    }

    func pause() {
        condition.lock()
        isPaused = true
        pendingPlayingEmission = true
        condition.unlock()
        emit(.paused)
    }

    func resume() {
        condition.lock()
        isPaused = false
        condition.signal()
        condition.unlock()
        emit(.playing)
    }

    func setPendingSeek(byteOffset: Int, positionMs: UInt32) {
        condition.lock()
        pendingSeek = (byteOffset, positionMs)
        pendingPlayingEmission = true
        condition.signal()
        condition.unlock()
    }

    func takePendingSeek() -> (byteOffset: Int, positionMs: UInt32)? {
        condition.lock()
        defer { condition.unlock() }
        let seek = pendingSeek
        pendingSeek = nil
        return seek
    }

    /// Parks while paused; returns `false` as soon as cancellation is observed (whether that was
    /// already true, or is what woke this call out of the park).
    func waitWhilePausedOrCancelled() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while isPaused, !isCancelled {
            condition.wait()
        }
        return !isCancelled
    }

    func isCancelledNow() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return isCancelled
    }

    func isPausedNow() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return isPaused
    }

    /// Test-and-clear: true only once per pause/seek, for the first write that follows it.
    func takePendingPlayingEmission() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard pendingPlayingEmission else { return false }
        pendingPlayingEmission = false
        return true
    }

    /// True only the first call for this pipeline instance; a caller that gets `false` should
    /// skip the join and the `.stopped` emit entirely (before `start()`, or a repeat call).
    func requestStop() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard hasStarted, !hasStoppedCalled else { return false }
        hasStoppedCalled = true
        isCancelled = true
        condition.broadcast()
        return true
    }

    /// Delivers `event` through the callback recorded at `start()`, unless `.stopped` has already
    /// gone out. `.stopped` itself sets that latch before its own callback runs, so a concurrent
    /// emit from the decode thread racing the very same moment still sees it and backs off --
    /// nothing can be observed after `.stopped`.
    func emit(_ event: VorbisDecodePipeline.Event) {
        condition.lock()
        guard !hasEmittedStopped else {
            condition.unlock()
            return
        }
        if case .stopped = event {
            hasEmittedStopped = true
        }
        let callback = events
        condition.unlock()
        callback?(event)
    }
}
