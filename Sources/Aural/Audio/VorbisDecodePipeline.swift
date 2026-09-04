//
//  VorbisDecodePipeline.swift
//  Aural
//
//  Stage 1 of #201, slice 2b (#208): drives `OggVorbisDecoder` from a `DecodeByteSource` to a
//  `PCMSink` on a dedicated thread. Not yet wired into playback -- the CDN fetcher, AES-CTR
//  decryptor, and `RustPlaybackEngine` wiring are other slices of #208. Nothing here decides how
//  bytes are fetched or decrypted, or how PCM reaches the speakers; it only paces decode against
//  the sink's backpressure and reports transport-relevant events.
//
//  Thread safety: `OggVorbisDecoder` requires a single owning thread end to end (see its own file
//  header), so this pipeline spins one dedicated `Thread` per `start()` call and keeps the decoder,
//  the pending-bytes buffer, and the read cursor as locals of that thread's own call stack -- never
//  stored properties, so nothing else can reach them. `pause`/`resume`/`seek`/`stop` are called from
//  whatever thread owns transport control (expected: the main actor) and only ever touch the
//  `NSCondition`-guarded gate state declared below. `events` is the one exception: it is written
//  once in `start()`, strictly before that call spins the thread, and never written again, so
//  every later reader (any thread) sees it via the happens-before edge `Thread.start()` already
//  establishes. Every stored property is therefore either an immutable `static let`, gate-guarded,
//  the semaphore itself, or that write-once closure -- so this class is safe to mark `@unchecked
//  Sendable`, which `Thread.init(block:)`'s `@Sendable` closure parameter requires of a capture.
//  A single controller still owns one instance for one track's playback; `Sendable` here describes
//  safe sharing across the two threads this type itself spins up, not an invitation to share wider.
//

import AuralDomain
import Foundation

/// Plumbing failures specific to driving the decoder from a byte source, distinct from
/// `OggVorbisDecoderError` (which is about the Vorbis stream itself).
enum VorbisDecodePipelineError: Error, Sendable {
    /// `openHeaders` never succeeded even after growing the prefix to the cap, or the source ran
    /// out of bytes before a full prefix could be read.
    case headerPrefixExceededLimit
    /// A seek's target byte offset has no `"OggS"` capture pattern within the search cap -- the
    /// offset is past the end of the stream, or not really inside an Ogg stream at all.
    case seekCaptureNotFound
    /// `blockingRead`'s semaphore woke without a result ever being recorded. Unreachable in
    /// practice -- the only signal comes right after the result is set -- but the switch must be
    /// exhaustive.
    case blockingReadIncomplete
}

/// Drives an `OggVorbisDecoder` from a `DecodeByteSource` to a `PCMSink` on a dedicated thread.
/// See the file header for the ownership, thread-confinement, and `@unchecked Sendable` rationale.
final class VorbisDecodePipeline: @unchecked Sendable {
    /// Decode-to-renderer pipeline events. Delivered on the decode thread; a caller that touches
    /// UI/main-actor state from `events` must hop back itself.
    ///
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

    /// Bound on how long `stop()` joins the decode thread. A read the source never completes (see
    /// `blockingRead`) cannot be cancelled out from under the thread, so this is a deadline on
    /// `stop()` returning, not a guarantee the thread has actually exited by then.
    private static let stopJoinTimeout: TimeInterval = 2.0

    /// Guards every field below. Also the condition the decode thread waits on for pause/resume,
    /// cancellation, and a pending seek -- see `waitWhilePausedOrCancelled`.
    private let gate = NSCondition()
    private var isPaused = false
    private var isCancelled = false
    private var hasStarted = false
    private var hasStoppedCalled = false
    private var pendingSeek: (byteOffset: Int, positionMs: UInt32)?

    /// Set once at `start()` and read-only after; safe to read from any thread without the gate.
    private var events: (@Sendable (Event) -> Void)?

    /// Signaled by the decode thread's closure just before it returns, so `stop()` can join it
    /// with a bound instead of blocking forever.
    private let threadFinished = DispatchSemaphore(value: 0)

    /// Spins the dedicated decode thread. No-op if already started.
    ///
    /// - Parameters:
    ///   - startOffset: byte offset of the first `"OggS"` in `source` (0xa7 in a Spotify file).
    ///   - startPositionMs: the position to report alongside the first decoded frame; later
    ///     decoded frames add their own elapsed time on top of this base.
    func start(
        source: DecodeByteSource,
        sink: PCMSink,
        startOffset: Int,
        startPositionMs: UInt32,
        events: @escaping @Sendable (Event) -> Void
    ) {
        gate.lock()
        guard !hasStarted else {
            gate.unlock()
            return
        }
        hasStarted = true
        self.events = events
        gate.unlock()

        let thread = Thread { [self] in
            runDecodeLoop(source: source, sink: sink, startOffset: startOffset, startPositionMs: startPositionMs)
            threadFinished.signal()
        }
        thread.name = "aural.decode"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Requests the decode loop park at its next between-frames check. Idempotent.
    func pause() {
        gate.lock()
        isPaused = true
        gate.unlock()
        events?(.paused)
    }

    /// Releases a paused decode loop. Idempotent; a no-op if not paused.
    func resume() {
        gate.lock()
        isPaused = false
        gate.signal()
        gate.unlock()
    }

    /// Records a pending seek for the decode loop to pick up between frames. A seek that arrives
    /// while another is still pending replaces it -- only the most recent target matters.
    func seek(toByteOffset byteOffset: Int, positionMs: UInt32) {
        gate.lock()
        pendingSeek = (byteOffset, positionMs)
        gate.signal()
        gate.unlock()
    }

    /// Cancels the decode loop, wakes it if parked, and joins it within a bound. No-op before
    /// `start()` and on a second call. Emits `.stopped` once the join returns (bound or not).
    func stop() {
        gate.lock()
        guard hasStarted, !hasStoppedCalled else {
            gate.unlock()
            return
        }
        hasStoppedCalled = true
        isCancelled = true
        gate.signal()
        gate.unlock()

        _ = threadFinished.wait(timeout: .now() + Self.stopJoinTimeout)
        events?(.stopped)
    }

    // MARK: - Decode thread

    /// Runs end to end on the dedicated decode thread: opens headers, then feeds/decodes/writes
    /// until the source is exhausted and the sink drains, or until failure/cancellation.
    private func runDecodeLoop(
        source: DecodeByteSource,
        sink: PCMSink,
        startOffset: Int,
        startPositionMs: UInt32
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
            events?(.failed(Self.headerFailure(for: error)))
            return
        }

        var basePositionMs = startPositionMs
        var decodedFrames: Int64 = 0
        var hasEmittedPlaying = false
        var lastPositionEmitUptime: TimeInterval = 0
        var sourceExhausted = false
        var frameBuffer: [Float] = []

        while true {
            guard waitWhilePausedOrCancelled() else { return }

            if let seek = takePendingSeek() {
                sink.flush()
                decoder.flush()
                do {
                    nextReadOffset = try captureOffsetAtOrAfter(seek.byteOffset, source: source)
                } catch {
                    events?(.failed(Self.seekFailure(for: error)))
                    return
                }
                pending.removeAll(keepingCapacity: true)
                sourceExhausted = false
                basePositionMs = seek.positionMs
                decodedFrames = 0
                events?(.seeked(seek.positionMs))
                continue
            }

            if pending.isEmpty {
                if sourceExhausted { break }
                do {
                    let chunk = try blockingRead(source: source, offset: nextReadOffset, length: Self.readChunkSize)
                    nextReadOffset += chunk.count
                    if chunk.isEmpty {
                        sourceExhausted = true
                    } else {
                        pending = chunk
                    }
                } catch {
                    events?(.failed(.sourceUnavailable))
                    return
                }
                continue
            }

            let result: (consumed: Int, frames: Int)
            do {
                result = try pending.withUnsafeBytes { try decoder.decodeFrame($0, into: &frameBuffer) }
            } catch {
                events?(.failed(.decodeFailed))
                return
            }

            if result.consumed == 0, result.frames == 0 {
                if sourceExhausted { break }
                do {
                    let chunk = try blockingRead(source: source, offset: nextReadOffset, length: Self.readChunkSize)
                    nextReadOffset += chunk.count
                    if chunk.isEmpty {
                        sourceExhausted = true
                    } else {
                        pending.append(chunk)
                    }
                } catch {
                    events?(.failed(.sourceUnavailable))
                    return
                }
                continue
            }

            pending.removeFirst(result.consumed)
            guard result.frames > 0 else { continue }

            decodedFrames += Int64(result.frames)
            frameBuffer.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                sink.write(base, count: buffer.count)  // blocks on backpressure; paces this loop
            }

            if !hasEmittedPlaying {
                hasEmittedPlaying = true
                events?(.playing)
            }

            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPositionEmitUptime >= Self.positionEmitInterval {
                lastPositionEmitUptime = now
                events?(.position(positionMs(basePositionMs: basePositionMs, decodedFrames: decodedFrames)))
            }
        }

        waitForSinkToDrain(sink)
        guard !isCancelledNow() else { return }
        events?(.endOfTrack)
    }

    /// Whether a header-stage or seek-stage throw is about the stream or about the bytes.
    ///
    /// The two stages share a `catch` with `blockingRead`, so a source failure and a malformed
    /// stream arrive the same way; the thrown type is what tells them apart. Mapping rather than
    /// stringifying keeps a signed CDN URL out of the reported failure -- see
    /// `AudioPipelineFailure`.
    private static func headerFailure(for error: Error) -> AudioPipelineFailure {
        error is VorbisDecodePipelineError || error is OggVorbisDecoderError
            ? .headerOpenFailed
            : .sourceUnavailable
    }

    private static func seekFailure(for error: Error) -> AudioPipelineFailure {
        error is VorbisDecodePipelineError ? .seekTargetNotFound : .sourceUnavailable
    }

    /// Grows the fed prefix (pushdata semantics require re-feeding from the start of the file,
    /// not just the new bytes -- see `OggVorbisDecoder.openHeaders`) until headers open or the
    /// cap is hit.
    private func openHeadersGrowingPrefix(
        source: DecodeByteSource,
        startOffset: Int,
        decoder: OggVorbisDecoder
    ) throws -> (consumed: Int, prefix: Data) {
        var prefixSize = Self.initialHeaderPrefixSize
        while true {
            let prefix = try blockingRead(source: source, offset: startOffset, length: prefixSize)
            do {
                let consumed = try prefix.withUnsafeBytes { try decoder.openHeaders($0) }
                return (consumed, prefix)
            } catch OggVorbisDecoderError.needMoreData {
                let sourceExhausted = prefix.count < prefixSize
                guard !sourceExhausted, prefixSize < Self.maxHeaderPrefixSize else {
                    throw VorbisDecodePipelineError.headerPrefixExceededLimit
                }
                prefixSize = min(prefixSize * 2, Self.maxHeaderPrefixSize)
            }
        }
    }

    /// Finds the `"OggS"` page boundary at or after `byteOffset`, growing the search window if
    /// one page's worth of bytes is not enough. `decoder.flush()` (already called by the caller)
    /// means stb_vorbis resynchronizes on whatever page boundary decoding resumes from.
    private func captureOffsetAtOrAfter(_ byteOffset: Int, source: DecodeByteSource) throws -> Int {
        var searchLength = Self.readChunkSize
        while true {
            let window = try blockingRead(source: source, offset: byteOffset, length: searchLength)
            if let captureOffset = OggPageHeader.nextCaptureOffset(in: window, from: 0) {
                return byteOffset + captureOffset
            }
            guard window.count == searchLength, searchLength < Self.maxSeekSearchSize else {
                throw VorbisDecodePipelineError.seekCaptureNotFound
            }
            searchLength = min(searchLength * 2, Self.maxSeekSearchSize)
        }
    }

    private func positionMs(basePositionMs: UInt32, decodedFrames: Int64) -> UInt32 {
        let decodedMs = Double(decodedFrames) / 44.1
        return UInt32(max(0, min(Double(UInt32.max), Double(basePositionMs) + decodedMs)))
    }

    /// Polls `sink.bufferedSeconds` down to ~0 (or the timeout) before `endOfTrack` is emitted, so
    /// Spirc does not advance the track while audio the sink already has is still playing out.
    private func waitForSinkToDrain(_ sink: PCMSink) {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.drainTimeout
        while sink.bufferedSeconds > Self.drainedThresholdSeconds {
            if isCancelledNow() || ProcessInfo.processInfo.systemUptime >= deadline { return }
            Thread.sleep(forTimeInterval: Self.drainPollInterval)
        }
    }

    private func waitWhilePausedOrCancelled() -> Bool {
        gate.lock()
        defer { gate.unlock() }
        while isPaused, !isCancelled {
            gate.wait()
        }
        return !isCancelled
    }

    private func takePendingSeek() -> (byteOffset: Int, positionMs: UInt32)? {
        gate.lock()
        defer { gate.unlock() }
        let seek = pendingSeek
        pendingSeek = nil
        return seek
    }

    private func isCancelledNow() -> Bool {
        gate.lock()
        defer { gate.unlock() }
        return isCancelled
    }

    /// Bridges `DecodeByteSource`'s async `read` onto the decode thread, which is a plain `Thread`
    /// and must never itself become `async` (stb_vorbis and the pending-bytes buffer are confined
    /// to it end to end). Only ever called from the decode thread started in `start()` -- calling
    /// it elsewhere would block that other thread on a semaphore for no reason.
    private func blockingRead(source: DecodeByteSource, offset: Int, length: Int) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingReadResult()
        Task {
            do {
                box.result = .success(try await source.read(offset: offset, length: length))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.result {
        case let .success(data): return data
        case let .failure(error): throw error
        case .none: throw VorbisDecodePipelineError.blockingReadIncomplete
        }
    }
}

/// Carries a `blockingRead` result across the semaphore: the writer (the `Task`) and the reader
/// (the decode thread after `semaphore.wait()`) never touch it concurrently.
private final class BlockingReadResult: @unchecked Sendable {
    var result: Result<Data, Error>?
}
