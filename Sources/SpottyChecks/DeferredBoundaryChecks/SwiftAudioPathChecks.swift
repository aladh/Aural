import SpottyDomain
import Foundation
@testable import SpottyCore

/// Reducer-to-effects checks for `SwiftAudioPath`: a parked decode source keeps the real
/// pipeline silent so assertions stay deterministic, and a second suite covers the
/// session-generation boundary the controller has to honor that the pure reducer already does.
@MainActor
func runSwiftAudioPathChecks(_ check: CheckRunner) async {
    await check.suite("Swift audio path") {
        await runLoadDrivesSourceAndOutputCheck(check)
        await runStaleGenerationProducesNoWorkCheck(check)
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
private func runLoadDrivesSourceAndOutputCheck(_ check: CheckRunner) async {
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
    check.check("a load asks the provider for a source", sourced)
    check.notNil("makeSource recorded a call", provider.calls.first)
    if let call = provider.calls.first {
        check.equal("makeSource receives the command's track GID", call.trackGID, trackGID)
        check.equal("makeSource receives the command's file id", call.fileID, fileA)
        check.equal("makeSource receives the command's Vorbis format", call.format, .oggVorbis160)
    }

    let started = await waitUntil { output.startCount >= 1 }
    check.check("the output is started once the pipeline is installed", started)
    let loading = await waitUntil { await path.phase == .loading(playRequestID: 100) }
    check.check("phase stays .loading while the pipeline is parked", loading)
    check.equal("a parked pipeline emits no reports", reports.all.count, 0)

    path.deliver(audioCommand(generation: 1, playRequestID: 100, kind: .stop))
    let stoppedOutput = await waitUntil(timeout: .seconds(5)) { output.stopCount >= 1 }
    check.check("stop tears the output down", stoppedOutput)
    let stopped = await waitUntil { await path.phase == .stopped }
    check.check("phase is .stopped after stop", stopped)

    release.signal()
    runTask.cancel()
}

/// An older-generation command must not start a source or emit a report. A newer-generation
/// load must tear the previous one down first, and any report that does go out must carry the
/// new stamp — not the abandoned load's.
@MainActor
private func runStaleGenerationProducesNoWorkCheck(_ check: CheckRunner) async {
    let provider = RecordingSourceProvider(source: ExhaustedTrackSource())
    let output = RecordingOutput()
    let reports = ReportCollector()
    let path = SwiftAudioPath(sources: provider, output: output, report: { reports.record($0) })
    let runTask = Task { await path.run() }

    path.deliver(audioCommand(generation: 7, playRequestID: 1, kind: .load, fileID: fileA))
    let firstSource = await waitUntil { provider.callCount == 1 }
    check.check("the first load creates a source", firstSource)
    let firstUnavailable = await waitUntil {
        reports.all.contains { $0.kind == .unavailable && $0.sessionGeneration == 7 }
    }
    check.check("the first load's failure reports generation 7", firstUnavailable)
    let startsAfterFirst = output.startCount
    let reportsAfterFirst = reports.all.count

    path.deliver(audioCommand(generation: 6, playRequestID: 1, kind: .play, fileID: fileA))
    let staleDidWork = await waitUntil(timeout: .milliseconds(300)) {
        provider.callCount > 1 || output.startCount > startsAfterFirst
            || reports.all.count > reportsAfterFirst
    }
    check.check(
        "an older-generation command produces no makeSource, no extra start, and no report",
        !staleDidWork && provider.callCount == 1
    )

    path.deliver(audioCommand(generation: 8, playRequestID: 2, kind: .load, fileID: fileB))
    let secondSource = await waitUntil { provider.callCount == 2 }
    check.check("a newer-generation load creates a second source", secondSource)
    check.equal("the second load uses the new file id", provider.calls.last?.fileID ?? [], fileB)
    let tornDown = await waitUntil { output.stopCount >= 1 }
    check.check("the newer load tears the previous pipeline/output down first", tornDown)
    let newStamp = await waitUntil {
        reports.all.contains { $0.kind == .unavailable && $0.sessionGeneration == 8 }
    }
    check.check("later reports carry the new session generation", newStamp)
    let firstNew = reports.all.firstIndex { $0.sessionGeneration == 8 }
    check.check(
        "no report after the second load still claims generation 7",
        firstNew.map { index in !reports.all[index...].contains { $0.sessionGeneration == 7 } } ?? false
    )

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
    private let source: any AudioTrackByteSource

    init(source: any AudioTrackByteSource) {
        self.source = source
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
        return source
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
