import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

/// Plumbing checks for `VorbisDecodePipeline`: the decode thread's lifecycle, failure paths, and
/// the pause/stop gate, driven entirely through fakes. `runFixtureDecodeThroughFakeSinkCheck`
/// additionally decodes the committed synthetic `tone-44100-stereo.ogg` fixture (#209).
@Test
@MainActor
func testVorbisDecodePipeline() async {
    do {
        await runGarbageSourceFailsCheck()
        await runThrowingSourceFailsCheck()
        runStopBeforeStartIsNoOpCheck()
        await runPauseGateStopTerminatesCheck()
        await runNoEventsAfterStoppedCheck()
        await runFixtureDecodeThroughFakeSinkCheck()
    }
}

/// A prefix of garbage never opens (see `OggVorbisDecoderChecks`'s own garbage-bytes check), so
/// the pipeline must grow the header prefix to its cap, give up, and emit `.failed` -- never hang
/// or crash trying to decode a frame with no open decoder.
@MainActor
private func runGarbageSourceFailsCheck() async {
    // One byte past the pipeline's 1 MiB header-prefix cap, so every growth step gets a full-length
    // read (never a short one) and the cap is what ends the search, not source exhaustion.
    let garbage = lcgBytes(count: 1_048_576 + 4_096, seed: 0x1234_5678_9abc_def0)
    let source = FakeByteSource(bytes: garbage)
    let sink = FakeSink()
    let collector = EventCollector()
    let pipeline = VorbisDecodePipeline()

    pipeline.start(source: source, sink: sink, startOffset: 0, startPositionMs: 0) { collector.record($0) }

    #expect(
        (await collector.waitForCount(1) && collector.all.first.map(isFailed) == true) == true,
        "garbage bytes emit .failed and the decode thread exits on its own")

    pipeline.stop()
    #expect(
        (await collector.waitForCount(2) && collector.all.last.map(isStopped) == true) == true,
        "stop() after the thread already exited still returns and emits .stopped")
}

/// A source whose very first read throws must fail the same way a decode error does -- the
/// pipeline does not distinguish "bad bytes" from "could not get bytes".
@MainActor
private func runThrowingSourceFailsCheck() async {
    struct FakeReadError: Error {}

    let source = FakeByteSource(readError: FakeReadError())
    let sink = FakeSink()
    let collector = EventCollector()
    let pipeline = VorbisDecodePipeline()

    pipeline.start(source: source, sink: sink, startOffset: 0, startPositionMs: 0) { collector.record($0) }

    #expect(
        (await collector.waitForCount(1) && collector.all.first.map(isFailed) == true) == true,
        "a throwing source emits .failed")

    pipeline.stop()
}

/// `stop()` before `start()` must not crash, hang, or emit anything -- there is no thread to join
/// and no `events` callback has ever been recorded.
@MainActor
private func runStopBeforeStartIsNoOpCheck() {
    let pipeline = VorbisDecodePipeline()
    pipeline.stop()
    #expect((true) == true, "stop() before start() returns without crashing or hanging")
}

/// A source whose read never returns on its own (until this check releases it) keeps the decode
/// thread parked inside `DecodeByteSource.read`, before it ever reaches the pause/cancel gate
/// between frames. `stop()` must still return within its bounded join instead of waiting on a
/// read that cannot be cancelled out from under the thread.
@MainActor
private func runPauseGateStopTerminatesCheck() async {
    let release = DispatchSemaphore(value: 0)
    let source = FakeByteSource(blockingUntil: release)
    let sink = FakeSink()
    let collector = EventCollector()
    let pipeline = VorbisDecodePipeline()

    pipeline.start(source: source, sink: sink, startOffset: 0, startPositionMs: 0) { collector.record($0) }

    // Give the decode thread a real chance to have entered the blocking read before pausing it.
    // This check exercises an actual OS thread parked on a real semaphore, which has no
    // observable condition to poll with `waitUntil` -- unlike the domain-level checks elsewhere
    // in this suite, so a short fixed async sleep is what is available here.
    try? await Task.sleep(for: .milliseconds(100))
    pipeline.pause()

    let stopStart = DispatchTime.now()
    pipeline.stop()
    let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - stopStart.uptimeNanoseconds) / 1e9

    #expect((elapsedSeconds < 2.5) == true, "stop() returns within its bounded join timeout even with a stuck read")
    #expect((collector.all.last.map(isStopped) == true) == true, "stop() still emits .stopped")

    // Release the parked read now that the assertions above are done, so the leaked decode thread
    // (stop()'s join was bounded, not a guarantee) can actually exit instead of staying parked for
    // the rest of the process.
    release.signal()
}

/// Once `.stopped` has gone out, nothing else may follow it -- `DecodeGate.emit` is a no-op for
/// every caller (decode thread or control thread) from that point on. Exercises that guarantee by
/// driving `pause`/`resume`/`seek`/`stop` again after the pipeline has already stopped.
@MainActor
private func runNoEventsAfterStoppedCheck() async {
    let garbage = lcgBytes(count: 1_048_576 + 4_096, seed: 0xabad_1dea_dead_beef)
    let source = FakeByteSource(bytes: garbage)
    let sink = FakeSink()
    let collector = EventCollector()
    let pipeline = VorbisDecodePipeline()

    pipeline.start(source: source, sink: sink, startOffset: 0, startPositionMs: 0) { collector.record($0) }

    #expect(
        (await collector.waitForCount(1) && collector.all.first.map(isFailed) == true) == true,
        "setup: garbage source reaches .failed")

    pipeline.stop()
    #expect(
        (await collector.waitForCount(2) && collector.all.last.map(isStopped) == true) == true,
        "setup: stop() after failure emits .stopped")

    let countAfterStop = collector.all.count

    pipeline.pause()
    pipeline.resume()
    pipeline.seek(toByteOffset: 0, positionMs: 0)
    pipeline.stop()

    #expect((collector.all.count == countAfterStop) == true, "no event is ever recorded after .stopped")
}

/// Feeds `Fixtures/tone-44100-stereo.ogg` (see `OggVorbisDecoderChecks`) through the pipeline end
/// to end with a `FakeByteSource`/`FakeSink` pair standing in for the CDN fetch and the renderer.
@MainActor
private func runFixtureDecodeThroughFakeSinkCheck() async {
    guard let data = bundledToneFixture() else { return }

    let source = FakeByteSource(bytes: [UInt8](data))
    let sink = FakeSink()
    let collector = EventCollector()
    let pipeline = VorbisDecodePipeline()

    pipeline.start(source: source, sink: sink, startOffset: 0, startPositionMs: 0) { collector.record($0) }

    #expect(
        (await waitUntil(timeout: .seconds(10)) { collector.all.contains(where: isEndOfTrack) }) == true,
        "fixture decode reaches .endOfTrack")
    #expect((collector.all.contains(where: isPlaying)) == true, "fixture decode emitted .playing before .endOfTrack")

    let totalFrames = sink.totalFrameCount
    #expect((totalFrames > 0) == true, "fixture decode produced frames")
    if let expectedFrames = lastGranulePosition(in: data) {
        #expect(
            (Int64(totalFrames)) == (expectedFrames),
            "fixture decoded frame count matches the last page's granule position")
    } else {
        #expect((false) == true, "fixture has a page with a resolved granule position")
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
/// semaphore until the check releases it. Only one behavior is configured per instance. `read` is
/// synchronous, matching the real protocol, so blocking on the semaphore here is just an ordinary
/// (if deliberately slow) function call -- no async bridging involved.
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

    var length: Int? { bytes?.count }

    func read(offset: Int, length: Int) throws -> Data {
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
/// Never cancels -- these checks care about the decode/threading plumbing, not backpressure.
private final class FakeSink: PCMSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frameCount = 0

    func write(_ samples: UnsafePointer<Float>, frames: Int, until cancelled: () -> Bool) -> PCMWriteOutcome {
        lock.lock()
        frameCount += frames
        lock.unlock()
        return .queued
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

/// Thread-safe collector for events delivered from the pipeline's dedicated decode thread (and,
/// for `.paused`/`.playing`/`.stopped`, from whatever thread called `pause`/`resume`/`stop`).
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [VorbisDecodePipeline.Event] = []

    func record(_ event: VorbisDecodePipeline.Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var all: [VorbisDecodePipeline.Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Polls (via the shared `waitUntil`) until at least `count` events have been recorded.
    @MainActor
    func waitForCount(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        await waitUntil(timeout: timeout) { self.all.count >= count }
    }
}
