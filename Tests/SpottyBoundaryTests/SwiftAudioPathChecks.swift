import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

/// Reducer-to-effects checks for `SwiftAudioPath`: a parked decode source keeps the real
/// pipeline silent so assertions stay deterministic, and a second suite covers the
/// session-generation boundary the controller has to honor that the pure reducer already does.
@Suite("Swift Audio Path")
struct SwiftAudioPathTests {
    @Test
    @MainActor
    func testSwiftAudioPath() async {
        do {
            await runLoadDrivesSourceAndOutputCheck()
            await runStaleGenerationProducesNoWorkCheck()
        }
    }
}

private let trackGID = [UInt8](repeating: 0xAB, count: 16)
private let fileA = [UInt8](repeating: 0x11, count: 20)
private let fileB = [UInt8](repeating: 0x22, count: 20)

private func audioCommand(
    generation: UInt64,
    playRequestID: UInt64,
    kind: AudioCommand.Kind,
    fileID: [UInt8] = fileA,
    startPlaying: Bool = true
) -> AudioCommand {
    AudioCommand(
        sessionGeneration: generation,
        playRequestID: playRequestID,
        kind: kind,
        trackURI: "spotify:track:fixture",
        trackGID: trackGID,
        fileID: fileID,
        audioFormat: SpotifyAudioFormat.oggVorbis160.rawValue,
        positionMs: 0,
        startPlaying: startPlaying,
        durationMs: 180_000
    )
}

/// A load with a source whose `read` parks must still call `makeSource` with the command's
/// identities, start the output, and stay `.loading` — the pipeline emits nothing while parked,
/// so phase cannot race ahead of what the reducer has confirmed.
@MainActor
private func runLoadDrivesSourceAndOutputCheck() async {
    let release = DispatchSemaphore(value: 0)
    let source = ParkingTrackSource(blockingUntil: release)
    let provider = RecordingSourceProvider(source: source)
    let output = RecordingOutput()
    let reports = ReportCollector()
    let path = SwiftAudioPath(sources: provider, output: output, report: { reports.record($0) })
    let runTask = Task { await path.run() }

    path.deliver(
        audioCommand(generation: 1, playRequestID: 100, kind: .load, startPlaying: true)
    )

    let sourced = await waitUntil { provider.callCount == 1 }
    #expect((sourced) == true, "a load asks the provider for a source")
    #expect((provider.calls.first) != nil, "makeSource recorded a call")
    if let call = provider.calls.first {
        #expect((call.trackGID) == (trackGID), "makeSource receives the command's track GID")
        #expect((call.fileID) == (fileA), "makeSource receives the command's file id")
        #expect((call.format) == (.oggVorbis160), "makeSource receives the command's Vorbis format")
    }

    let started = await waitUntil { output.startCount >= 1 }
    #expect((started) == true, "the output is started once the pipeline is installed")
    let loading = await waitUntil { await path.phase == .loading(playRequestID: 100) }
    #expect((loading) == true, "phase stays .loading while the pipeline is parked")
    #expect(
        (reports.all.map(\.kind)) == ([AudioReportKind.duration]),
        "a parked pipeline's only report is the load's known duration")

    path.deliver(audioCommand(generation: 1, playRequestID: 100, kind: .stop))
    let stoppedOutput = await waitUntil(timeout: .seconds(5)) { output.stopCount >= 1 }
    #expect((stoppedOutput) == true, "stop tears the output down")
    // `pipeline.stop()` joins the decode thread on the audio-path actor. Unpark the
    // read so that join can finish before waiting on actor state.
    release.signal()
    let stopped = await waitUntil(timeout: .seconds(5)) { await path.phase == .stopped }
    #expect((stopped) == true, "phase is .stopped after stop")

    runTask.cancel()
}

/// An older-generation command must not start a source or emit a report. A newer-generation
/// load must tear the previous one down first, and any report that does go out must carry the
/// new stamp — not the abandoned load's.
///
/// The first load parks so the pipeline stays live (a load that already failed to `.stopped`
/// does not emit `.stop` on the next load). The second load uses an exhausting source so the
/// reducer emits a deterministic `.unavailable` stamped with the new generation.
@MainActor
private func runStaleGenerationProducesNoWorkCheck() async {
    let release = DispatchSemaphore(value: 0)
    let parked = ParkingTrackSource(blockingUntil: release)
    let exhausted = ExhaustedTrackSource()
    let provider = RecordingSourceProvider { (fileID: [UInt8]) -> any AudioTrackByteSource in
        if fileID == fileA {
            parked
        } else {
            exhausted
        }
    }
    let output = RecordingOutput()
    let reports = ReportCollector()
    let path = SwiftAudioPath(sources: provider, output: output, report: { reports.record($0) })
    let runTask = Task { await path.run() }

    path.deliver(audioCommand(generation: 7, playRequestID: 1, kind: .load, fileID: fileA))
    let firstSource = await waitUntil { provider.callCount == 1 }
    #expect((firstSource) == true, "the first load creates a source")
    let loading = await waitUntil { await path.phase == .loading(playRequestID: 1) }
    #expect((loading) == true, "the first load stays .loading while parked")
    #expect((output.stopCount) == (0), "a live parked load has not stopped the output yet")
    let reportsAfterFirst = reports.all.count
    let startsAfterFirst = output.startCount

    path.deliver(audioCommand(generation: 6, playRequestID: 1, kind: .play, fileID: fileA))
    let staleDidWork = await waitUntil(timeout: .milliseconds(300)) {
        provider.callCount > 1 || output.startCount > startsAfterFirst
            || reports.all.count > reportsAfterFirst
    }
    #expect(
        (!staleDidWork && provider.callCount == 1) == true,
        "an older-generation command produces no makeSource, no extra start, and no report")

    path.deliver(audioCommand(generation: 8, playRequestID: 2, kind: .load, fileID: fileB))
    let tornDown = await waitUntil(timeout: .seconds(5)) { output.stopCount >= 1 }
    #expect((tornDown) == true, "the newer load tears the previous pipeline/output down first")
    // Unpark the first decode so teardown can leave the actor and the replacement load can run.
    release.signal()
    let secondSource = await waitUntil(timeout: .seconds(5)) { provider.callCount == 2 }
    #expect((secondSource) == true, "a newer-generation load creates a second source")
    #expect((provider.calls.last?.fileID ?? []) == (fileB), "the second load uses the new file id")
    let newStamp = await waitUntil(timeout: .seconds(5)) {
        reports.all.contains { $0.kind == .unavailable && $0.sessionGeneration == 8 }
    }
    #expect((newStamp) == true, "later reports carry the new session generation")
    #expect(
        (!reports.all.contains { $0.sessionGeneration == 7 && $0.kind != .duration }) == true,
        "no transport report still claims the abandoned generation")

    runTask.cancel()
}

// MARK: - Fakes

private struct SourceCall: Equatable, Sendable {
    var trackGID: [UInt8]
    var fileID: [UInt8]
    var format: SpotifyAudioFormat
}

private final class RecordingSourceProvider: AudioTrackByteSourceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SourceCall] = []
    private let sourceForFileID: @Sendable ([UInt8]) -> any AudioTrackByteSource

    init(source: any AudioTrackByteSource) {
        sourceForFileID = { _ in source }
    }

    init(sourceForFileID: @escaping @Sendable ([UInt8]) -> any AudioTrackByteSource) {
        self.sourceForFileID = sourceForFileID
    }

    var calls: [SourceCall] { lock.withLock { recorded } }
    var callCount: Int { lock.withLock { recorded.count } }

    func makeSource(
        trackGID: [UInt8],
        fileID: [UInt8],
        format: SpotifyAudioFormat
    ) async throws -> any AudioTrackByteSource {
        lock.withLock {
            recorded.append(SourceCall(trackGID: trackGID, fileID: fileID, format: format))
        }
        return sourceForFileID(fileID)
    }
}

/// Parks every synchronous `read` so the real decode thread emits nothing. Async range reads
/// used by the seeker return empty immediately — these checks load from position 0, so the
/// seeker is not invoked.
private final class ParkingTrackSource: AudioTrackByteSource, @unchecked Sendable {
    private let blockingSemaphore: DispatchSemaphore

    init(blockingUntil semaphore: DispatchSemaphore) {
        blockingSemaphore = semaphore
    }

    var length: Int? { 4_096 }

    func read(offset: Int, length: Int) throws -> Data {
        blockingSemaphore.wait()
        return Data()
    }

    func readRange(offset: Int, length: Int) async throws -> Data { Data() }
    func totalLength() async throws -> Int { 4_096 }
    func downloadFully() async throws {}
    func prefetchAhead(ofPositionMs positionMs: UInt32) async {}
}

/// Exhausts on the first decode read so the pipeline fails quickly and the reducer emits a
/// deterministic `.unavailable` report for generation assertions.
private final class ExhaustedTrackSource: AudioTrackByteSource, @unchecked Sendable {
    var length: Int? { 4_096 }
    func read(offset: Int, length: Int) throws -> Data { Data() }
    func readRange(offset: Int, length: Int) async throws -> Data { Data() }
    func totalLength() async throws -> Int { 4_096 }
    func downloadFully() async throws {}
    func prefetchAhead(ofPositionMs positionMs: UInt32) async {}
}

private final class RecordingOutput: AudioOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func start() { lock.withLock { starts += 1 } }
    func stop() { lock.withLock { stops += 1 } }
    func write(_ samples: UnsafePointer<Float>, frames: Int, until cancelled: () -> Bool) -> PCMWriteOutcome {
        .queued
    }
    func flush() {}
    var bufferedSeconds: Double { 0 }
}

private final class ReportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [AudioReport] = []

    func record(_ report: AudioReport) {
        lock.withLock { reports.append(report) }
    }

    var all: [AudioReport] { lock.withLock { reports } }
}
