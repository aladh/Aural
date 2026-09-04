import AuralDomain
import Foundation
@testable import AuralCore

/// Plumbing checks for `VorbisDecodePipeline`: the decode thread's lifecycle, failure paths, and
/// the pause/stop gate, driven entirely through fakes. No Vorbis fixture is committed on `main`
/// yet (see `OggVorbisDecoderChecks`), so the one real-decode check is guarded and skips when the
/// fixture is absent rather than failing the gate.
@MainActor
func runVorbisDecodePipelineChecks(_ check: CheckRunner) {
    check.suite("Vorbis decode pipeline") {
        runGarbageSourceFailsCheck(check)
        runThrowingSourceFailsCheck(check)
        runStopBeforeStartIsNoOpCheck(check)
        runPauseGateStopTerminatesCheck(check)
        runFixtureDecodeThroughFakeSinkCheck(check)
    }
}

/// A prefix of garbage never opens (see `OggVorbisDecoderChecks`'s own garbage-bytes check), so
/// the pipeline must grow the header prefix to its cap, give up, and emit `.failed` -- never hang
/// or crash trying to decode a frame with no open decoder.
private func runGarbageSourceFailsCheck(_ check: CheckRunner) {
    // One byte past the pipeline's 1 MiB header-prefix cap, so every growth step gets a full-length
    // read (never a short one) and the cap is what ends the search, not source exhaustion.
    let garbage = lcgBytes(count: 1_048_576 + 4_096, seed: 0x1234_5678_9abc_def0)
    let source = FakeByteSource(bytes: garbage)
    let sink = FakeSink()
    let collector = EventCollector()
    let pipeline = VorbisDecodePipeline()

    pipeline.start(source: source, sink: sink, startOffset: 0, startPositionMs: 0) { collector.record($0) }

    check.check(
        "garbage bytes emit .failed and the decode thread exits on its own",
        collector.waitForCount(1, timeoutMilliseconds: 5_000) && collector.all.first.map(isFailed) == true
    )

    pipeline.stop()
    check.check(
        "stop() after the thread already exited still returns and emits .stopped",
        collector.waitForCount(2, timeoutMilliseconds: 2_000) && collector.all.last.map(isStopped) == true
    )
}

/// A source whose very first read throws must fail the same way a decode error does -- the
/// pipeline does not distinguish "bad bytes" from "could not get bytes".
private func runThrowingSourceFailsCheck(_ check: CheckRunner) {
    struct FakeReadError: Error {}

    let source = FakeByteSource(readError: FakeReadError())
    let sink = FakeSink()
    let collector = EventCollector()
    let pipeline = VorbisDecodePipeline()

    pipeline.start(source: source, sink: sink, startOffset: 0, startPositionMs: 0) { collector.record($0) }

    check.check(
        "a throwing source emits .failed",
        collector.waitForCount(1, timeoutMilliseconds: 5_000) && collector.all.first.map(isFailed) == true
    )

    pipeline.stop()
}

/// `stop()` before `start()` must not crash, hang, or emit anything -- there is no thread to join
/// and no `events` callback has ever been recorded.
private func runStopBeforeStartIsNoOpCheck(_ check: CheckRunner) {
    let pipeline = VorbisDecodePipeline()
    pipeline.stop()
    check.check("stop() before start() returns without crashing or hanging", true)
}

/// A source whose read never returns on its own (until this check releases it) keeps the decode
/// thread parked inside `blockingRead`, before it ever reaches the pause/cancel gate between
/// frames. `stop()` must still return within its bounded join instead of waiting on a read that
/// cannot be cancelled out from under the thread.
private func runPauseGateStopTerminatesCheck(_ check: CheckRunner) {
    let release = DispatchSemaphore(value: 0)
    let source = FakeByteSource(blockingUntil: release)
    let sink = FakeSink()
    let collector = EventCollector()
    let pipeline = VorbisDecodePipeline()

    pipeline.start(source: source, sink: sink, startOffset: 0, startPositionMs: 0) { collector.record($0) }

    // Give the decode thread a real chance to have entered the blocking read before pausing it.
    // This check exercises an actual OS thread parked on a real semaphore, which has no
    // deterministic handshake to wait on instead -- unlike the domain-level checks elsewhere in
    // this suite.
    Thread.sleep(forTimeInterval: 0.1)
    pipeline.pause()

    let stopStart = DispatchTime.now()
    pipeline.stop()
    let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - stopStart.uptimeNanoseconds) / 1e9

    check.check("stop() returns within its bounded join timeout even with a stuck read", elapsedSeconds < 2.5)
    check.check("stop() still emits .stopped", collector.all.last.map(isStopped) == true)

    // Release the parked read now that the assertions above are done, so the leaked decode thread
    // (stop()'s join was bounded, not a guarantee) can actually exit instead of staying parked for
    // the rest of the process.
    release.signal()
}

/// Feeds `Fixtures/tone-44100-stereo.ogg` (see `OggVorbisDecoderChecks`) through the pipeline end
/// to end with a `FakeByteSource`/`FakeSink` pair standing in for the CDN fetch and the renderer.
/// Skips with a passing check when the fixture is absent, same as `OggVorbisDecoderChecks`.
private func runFixtureDecodeThroughFakeSinkCheck(_ check: CheckRunner) {
    let data: Data
    do {
        data = try boundaryFixture(named: "tone-44100-stereo", extension: "ogg")
    } catch {
        check.check("tone-44100-stereo.ogg fixture absent; pipeline decode check skipped", true)
        return
    }

    let source = FakeByteSource(bytes: [UInt8](data))
    let sink = FakeSink()
    let collector = EventCollector()
    let pipeline = VorbisDecodePipeline()

    pipeline.start(source: source, sink: sink, startOffset: 0, startPositionMs: 0) { collector.record($0) }

    check.check(
        "fixture decode reaches .endOfTrack",
        collector.waitForEvent(timeoutMilliseconds: 10_000, matching: isEndOfTrack)
    )
    check.check("fixture decode emitted .playing before .endOfTrack", collector.all.contains(where: isPlaying))

    let totalFrames = sink.totalFrameCount
    check.check("fixture decode produced frames", totalFrames > 0)
    if let expectedFrames = lastGranulePosition(in: data) {
        check.equal(
            "fixture decoded frame count matches the last page's granule position",
            Int64(totalFrames),
            expectedFrames
        )
    } else {
        check.check("fixture has a page with a resolved granule position", false)
    }

    pipeline.stop()
}

// MARK: - Event matching

private func isFailed(_ event: VorbisDecodePipeline.Event) -> Bool {
    if case .failed = event { return true }
    return false
}

private func isStopped(_ event: VorbisDecodePipeline.Event) -> Bool {
    if case .stopped = event { return true }
    return false
}

private func isPlaying(_ event: VorbisDecodePipeline.Event) -> Bool {
    if case .playing = event { return true }
    return false
}

private func isEndOfTrack(_ event: VorbisDecodePipeline.Event) -> Bool {
    if case .endOfTrack = event { return true }
    return false
}

// MARK: - Fakes

/// Fake `DecodeByteSource`: serves a fixed byte array, always throws, or blocks every read on a
/// semaphore until the check releases it. Only one behavior is configured per instance.
private final class FakeByteSource: DecodeByteSource, @unchecked Sendable {
    private let bytes: [UInt8]?
    private let readError: Error?
    private let blockingSemaphore: DispatchSemaphore?

    init(bytes: [UInt8]) {
        self.bytes = bytes
        self.readError = nil
        self.blockingSemaphore = nil
    }

    init(readError: Error) {
        self.bytes = nil
        self.readError = readError
        self.blockingSemaphore = nil
    }

    init(blockingUntil semaphore: DispatchSemaphore) {
        self.bytes = nil
        self.readError = nil
        self.blockingSemaphore = semaphore
    }

    var length: Int? {
        get async { bytes?.count }
    }

    func read(offset: Int, length: Int) async throws -> Data {
        if let blockingSemaphore {
            blockingSemaphore.wait()
            return Data()
        }
        if let readError {
            throw readError
        }
        guard let bytes, offset < bytes.count else { return Data() }
        let end = min(offset + length, bytes.count)
        return Data(bytes[offset..<end])
    }
}

/// Fake `PCMSink`: records every write and reports zero buffered seconds, so `endOfTrack` fires
/// as soon as decoding is done rather than waiting out a drain that never applies to a fake.
private final class FakeSink: PCMSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frameCount = 0

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        lock.lock()
        frameCount += count / 2  // interleaved stereo
        lock.unlock()
    }

    func flush() {
        lock.lock()
        frameCount = 0
        lock.unlock()
    }

    var bufferedSeconds: Double { 0 }

    var totalFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCount
    }
}

/// Thread-safe collector for events delivered from the pipeline's dedicated decode thread.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [VorbisDecodePipeline.Event] = []
    private let signal = DispatchSemaphore(value: 0)

    func record(_ event: VorbisDecodePipeline.Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
        signal.signal()
    }

    var all: [VorbisDecodePipeline.Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Blocks (bounded by `timeoutMilliseconds`) until at least `count` events have been recorded.
    func waitForCount(_ count: Int, timeoutMilliseconds: Int) -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
        while currentCount < count {
            if signal.wait(timeout: deadline) == .timedOut {
                return currentCount >= count
            }
        }
        return true
    }

    /// Blocks (bounded by `timeoutMilliseconds`) until some recorded event matches `predicate`.
    func waitForEvent(
        timeoutMilliseconds: Int,
        matching predicate: (VorbisDecodePipeline.Event) -> Bool
    ) -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
        while !all.contains(where: predicate) {
            if signal.wait(timeout: deadline) == .timedOut {
                return all.contains(where: predicate)
            }
        }
        return true
    }

    private var currentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }
}

/// LCG-generated bytes so the garbage-input check is deterministic across runs -- mirrors
/// `OggVorbisDecoderChecks`'s own helper of the same shape.
private func lcgBytes(count: Int, seed: UInt64) -> [UInt8] {
    var state = seed
    var bytes = [UInt8]()
    bytes.reserveCapacity(count)
    for _ in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bytes.append(UInt8(truncatingIfNeeded: state >> 56))
    }
    return bytes
}

/// Walks Ogg pages via `OggPageHeader` to find the granule position of the last page that
/// finishes a packet -- mirrors `OggVorbisDecoderChecks`'s own helper of the same shape.
private func lastGranulePosition(in data: Data) -> Int64? {
    var offset = 0
    var last: Int64?
    while let captureOffset = OggPageHeader.nextCaptureOffset(in: data, from: offset) {
        guard let header = OggPageHeader.parse(data, at: captureOffset), header.totalLength > 0 else { break }
        if header.granulePosition != -1 {
            last = header.granulePosition
        }
        offset = captureOffset + header.totalLength
    }
    return last
}
