import Testing
import SpottyDomain

private let gid = [UInt8](repeating: 0xAB, count: 16)
private let fileA = [UInt8](repeating: 0x01, count: 20)
private let fileB = [UInt8](repeating: 0x02, count: 20)

private func command(
    generation: UInt64 = 1,
    playRequestID: UInt64 = 100,
    kind: AudioCommand.Kind,
    trackURI: String = "spotify:track:one",
    fileID: [UInt8] = fileA,
    positionMs: UInt32 = 0,
    startPlaying: Bool = true,
    durationMs: UInt32 = 0
) -> AudioCommand {
    AudioCommand(
        sessionGeneration: generation,
        playRequestID: playRequestID,
        kind: kind,
        trackURI: trackURI,
        trackGID: gid,
        fileID: fileID,
        audioFormat: 4,
        positionMs: positionMs,
        startPlaying: startPlaying,
        durationMs: durationMs
    )
}

private func delivery(
    _ event: AudioPlaybackSession.PipelineEvent,
    generation: UInt64 = 1,
    playRequestID: UInt64 = 100
) -> AudioPlaybackSession.PipelineEventDelivery {
    AudioPlaybackSession.PipelineEventDelivery(
        sessionGeneration: generation,
        playRequestID: playRequestID,
        event: event
    )
}

@Suite("Audio Playback Session")
struct AudioPlaybackSessionTests {
    @Test
    func testAudioPlaybackSession() {
        do {
            checkStaleGeneration()
            checkNewerGenerationTearsDownLivePipeline()
            checkNewerGenerationCancelsHeldPreload()
            checkLoadStopsAnyLivePhaseNotOnlyPlaying()
            checkPreloadReuse()
            checkPreloadOverwriteCancelsThePrevious()
            checkSeekClamp()
            checkLoadingPhaseHonorsTransportCommands()
            checkLoadWithKnownDurationReportsOnce()
            checkTimeToPreloadNextOnce()
            checkEndOfTrackResetsToIdle()
            checkFailedReportsUnavailable()
            checkReportsCarryCurrentIdentity()
            checkPlayPauseWhenIdleAreNoOps()
            checkPipelineEventsAreScopedToCurrent()
        }
    }
}

private func checkStaleGeneration() {
    var session = AudioPlaybackSession(sessionGeneration: 5)
    let stale = command(generation: 3, kind: .play)
    let effects = session.apply(stale)
    #expect((effects) == ([.ignoreStale(stale)]), "a stale generation is ignored")
    #expect((session.sessionGeneration) == (5), "the session generation is unchanged")
    #expect((session.phase) == (.idle), "the phase is unchanged")
}

private func checkNewerGenerationTearsDownLivePipeline() {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    _ = session.apply(pipelineEvent: delivery(.playing, playRequestID: 100))
    #expect((session.phase) == (.playing(playRequestID: 100)), "the session is playing before the reset")

    let load = command(generation: 2, playRequestID: 200, kind: .load, fileID: fileB, startPlaying: true)
    let effects = session.apply(load)

    #expect(
        (effects)
            == ([
                .stop,
                .beginLoad(session.current!, startPlaying: true, positionMs: 0, reusingPreload: false),
            ]), "a newer generation stops a live pipeline before loading")
    #expect((session.sessionGeneration) == (2), "the session generation is adopted")
}

private func checkNewerGenerationCancelsHeldPreload() {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(generation: 1, playRequestID: 90, kind: .preload, fileID: fileB))
    #expect((session.preloaded) != nil, "a preload is held before the reset")

    let load = command(generation: 2, playRequestID: 200, kind: .load, fileID: fileA, startPlaying: true)
    let effects = session.apply(load)

    #expect(
        (effects)
            == ([
                .cancelPreload(playRequestID: 90),
                .beginLoad(session.current!, startPlaying: true, positionMs: 0, reusingPreload: false),
            ]), "a dropped preload is cancelled before the reset load runs")
    #expect((session.preloaded) == nil, "the stale preload is dropped by the reset")
}

private func checkLoadStopsAnyLivePhaseNotOnlyPlaying() {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    #expect((session.phase) == (.loading(playRequestID: 100)), "the first load is still loading")

    let secondLoad = command(playRequestID: 101, kind: .load, trackURI: "spotify:track:two", fileID: fileB)
    let effects = session.apply(secondLoad)

    #expect(
        (effects)
            == ([
                .stop,
                .beginLoad(session.current!, startPlaying: true, positionMs: 0, reusingPreload: false),
            ]), "a stop effect precedes beginLoad when the previous load was still loading")
    #expect((session.phase) == (.loading(playRequestID: 101)), "the phase moves to loading the new request")
}

private func checkPreloadReuse() {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    _ = session.apply(pipelineEvent: delivery(.playing, playRequestID: 100))

    let preload = session.apply(
        command(playRequestID: 101, kind: .preload, trackURI: "spotify:track:two", fileID: fileB)
    )
    #expect((session.preloaded) != nil, "the preloaded track is held")
    let emitsBeginPreload = preload.contains { effect in
        if case .beginPreload = effect { return true }
        return false
    }
    #expect((emitsBeginPreload) == true, "beginPreload is emitted")

    let load = command(
        playRequestID: 102, kind: .load, trackURI: "spotify:track:two", fileID: fileB, startPlaying: true
    )
    let effects = session.apply(load)

    #expect(
        (effects)
            == ([
                .stop,
                .beginLoad(session.current!, startPlaying: true, positionMs: 0, reusingPreload: true),
            ]), "a load matching the preloaded file id reuses it without cancelling it")
    #expect((session.preloaded) == nil, "the consumed preload slot is cleared")
}

private func checkPreloadOverwriteCancelsThePrevious() {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    let firstPreload = session.apply(
        command(playRequestID: 100, kind: .preload, trackURI: "spotify:track:one", fileID: fileA)
    )
    #expect((firstPreload) == ([.beginPreload(session.preloaded!)]), "the first preload has nothing to cancel")

    let secondPreload = session.apply(
        command(playRequestID: 101, kind: .preload, trackURI: "spotify:track:two", fileID: fileB)
    )
    #expect(
        (secondPreload)
            == ([
                .cancelPreload(playRequestID: 100),
                .beginPreload(session.preloaded!),
            ]), "overwriting a held preload cancels it before starting the new one")
}

private func checkSeekClamp() {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: false, durationMs: 10_000)
    )
    _ = session.apply(pipelineEvent: delivery(.paused, playRequestID: 100))

    let withinBounds = session.apply(command(playRequestID: 100, kind: .seek, positionMs: 4_000))
    #expect((withinBounds) == ([.seek(positionMs: 4_000)]), "a seek within duration passes through")

    let pastEnd = session.apply(command(playRequestID: 100, kind: .seek, positionMs: 50_000))
    #expect((pastEnd) == ([.seek(positionMs: 10_000)]), "a seek past the known duration clamps to it")
    #expect((session.positionMs) == (10_000), "the clamped position is retained")
}

private func checkLoadingPhaseHonorsTransportCommands() {
    var pauseDuringLoad = AudioPlaybackSession(sessionGeneration: 1)
    _ = pauseDuringLoad.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true)
    )
    let pauseEffects = pauseDuringLoad.apply(command(playRequestID: 100, kind: .pause))
    #expect((pauseEffects) == ([.pause]), "pause during loading is queued for the pipeline")
    #expect(
        (pauseDuringLoad.phase) == (.loading(playRequestID: 100)), "pause during loading does not force a phase jump")

    var playDuringLoad = AudioPlaybackSession(sessionGeneration: 1)
    _ = playDuringLoad.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: false)
    )
    let playEffects = playDuringLoad.apply(command(playRequestID: 100, kind: .play))
    #expect((playEffects) == ([.play]), "play during loading is queued for the pipeline")
    #expect((playDuringLoad.phase) == (.loading(playRequestID: 100)), "play during loading does not force a phase jump")

    var seekDuringLoad = AudioPlaybackSession(sessionGeneration: 1)
    _ = seekDuringLoad.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true, durationMs: 10_000)
    )
    let seekEffects = seekDuringLoad.apply(command(playRequestID: 100, kind: .seek, positionMs: 3_000))
    #expect((seekEffects) == ([.seek(positionMs: 3_000)]), "seek during loading is queued for the pipeline")
    #expect((seekDuringLoad.phase) == (.loading(playRequestID: 100)), "seek during loading does not force a phase jump")
    #expect((seekDuringLoad.positionMs) == (3_000), "the position is updated immediately")
}

private func checkLoadWithKnownDurationReportsOnce() {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    let effects = session.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true, durationMs: 180_000)
    )
    #expect(
        (effects)
            == ([
                .beginLoad(session.current!, startPlaying: true, positionMs: 0, reusingPreload: false),
                .report(
                    AudioReport(
                        sessionGeneration: 1, playRequestID: 100, kind: .duration, positionMs: 0, durationMs: 180_000
                    )
                ),
            ]), "a load that already knows duration reports it once")
    #expect((session.current?.durationMs) == (Optional(180_000 as UInt32)), "LoadedTrack keeps the command duration")

    var unknown = AudioPlaybackSession(sessionGeneration: 1)
    let unknownEffects = unknown.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    #expect(
        (unknownEffects) == ([.beginLoad(unknown.current!, startPlaying: true, positionMs: 0, reusingPreload: false)]),
        "a load with unknown duration does not invent a duration report")
}

private func checkTimeToPreloadNextOnce() {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true, durationMs: 40_000)
    )
    _ = session.apply(pipelineEvent: delivery(.playing, playRequestID: 100))

    let beforeWindow = session.apply(pipelineEvent: delivery(.position(5_000), playRequestID: 100))
    #expect((beforeWindow.count) == (1), "no preload-next report before the window")

    let enteringWindow = session.apply(pipelineEvent: delivery(.position(12_000), playRequestID: 100))
    #expect(
        (enteringWindow)
            == ([
                .report(
                    AudioReport(
                        sessionGeneration: 1, playRequestID: 100, kind: .position, positionMs: 12_000,
                        durationMs: 40_000
                    )
                ),
                .report(
                    AudioReport(
                        sessionGeneration: 1,
                        playRequestID: 100,
                        kind: .timeToPreloadNext,
                        positionMs: 12_000,
                        durationMs: 40_000
                    )
                ),
            ]), "entering the 30s window reports timeToPreloadNext once")

    let stillWithinWindow = session.apply(pipelineEvent: delivery(.position(13_000), playRequestID: 100))
    #expect((stillWithinWindow.count) == (1), "it does not repeat for the same load")
}

private func checkEndOfTrackResetsToIdle() {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true, durationMs: 5_000)
    )
    _ = session.apply(pipelineEvent: delivery(.playing, playRequestID: 100))

    let effects = session.apply(pipelineEvent: delivery(.endOfTrack, playRequestID: 100))

    #expect(
        (effects)
            == ([
                .report(
                    AudioReport(
                        sessionGeneration: 1, playRequestID: 100, kind: .endOfTrack, positionMs: 5_000,
                        durationMs: 5_000
                    )
                )
            ]), "endOfTrack reports and resets to idle")
    #expect((session.phase) == (.idle), "the phase is idle")
    #expect((session.current) == nil, "current is cleared")
    #expect((session.positionMs) == (0), "position resets")
}

private func checkFailedReportsUnavailable() {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    _ = session.apply(pipelineEvent: delivery(.playing, playRequestID: 100))

    let effects = session.apply(pipelineEvent: delivery(.failed(.decode), playRequestID: 100))

    #expect(
        (effects)
            == ([
                .report(
                    AudioReport(
                        sessionGeneration: 1, playRequestID: 100, kind: .unavailable, positionMs: 0, durationMs: 0)
                )
            ]), "failed reports unavailable")
    #expect((session.phase) == (.stopped), "the phase moves to stopped")
    #expect((session.current) == nil, "current is cleared")
}

private func checkReportsCarryCurrentIdentity() {
    var session = AudioPlaybackSession(sessionGeneration: 7)
    _ = session.apply(command(generation: 7, playRequestID: 55, kind: .load, fileID: fileA, startPlaying: true))
    let effects = session.apply(pipelineEvent: delivery(.playing, generation: 7, playRequestID: 55))

    #expect(
        (effects)
            == ([
                .report(
                    AudioReport(sessionGeneration: 7, playRequestID: 55, kind: .playing, positionMs: 0, durationMs: 0))
            ]), "a report stamps the session generation and the current play request id")
}

private func checkPlayPauseWhenIdleAreNoOps() {
    var session = AudioPlaybackSession(sessionGeneration: 1)

    #expect((session.apply(command(kind: .play)).isEmpty) == true, "play emits nothing when idle")
    #expect((session.apply(command(kind: .pause)).isEmpty) == true, "pause emits nothing when idle")
    #expect((session.apply(command(kind: .seek)).isEmpty) == true, "seek emits nothing when idle")
    #expect((session.apply(command(kind: .stop)).isEmpty) == true, "stop emits nothing when idle")
    #expect((session.phase) == (.idle), "the phase stays idle")
}

private func checkPipelineEventsAreScopedToCurrent() {
    var noCurrent = AudioPlaybackSession(sessionGeneration: 1)
    let ignoredWithNothingLoaded = noCurrent.apply(pipelineEvent: delivery(.endOfTrack, playRequestID: 100))
    #expect((ignoredWithNothingLoaded.isEmpty) == true, "every pipeline event is ignored when nothing is loaded")

    var superseded = AudioPlaybackSession(sessionGeneration: 1)
    _ = superseded.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    _ = superseded.apply(pipelineEvent: delivery(.playing, playRequestID: 100))
    _ = superseded.apply(command(playRequestID: 101, kind: .load, trackURI: "spotify:track:two", fileID: fileB))
    #expect((superseded.current?.playRequestID) == (101), "the second load is current")

    let staleEndOfTrack = superseded.apply(pipelineEvent: delivery(.endOfTrack, playRequestID: 100))
    #expect(
        (staleEndOfTrack) == ([.ignoreStalePipelineEvent(delivery(.endOfTrack, playRequestID: 100))]),
        "a stale playRequestID is ignored instead of applied")
    #expect((superseded.phase) != (.idle), "the current load is untouched")
    #expect((superseded.current?.playRequestID) == (101), "the current identity is unchanged")

    var stopped = AudioPlaybackSession(sessionGeneration: 1)
    _ = stopped.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    _ = stopped.apply(pipelineEvent: delivery(.playing, playRequestID: 100))
    _ = stopped.apply(command(playRequestID: 100, kind: .stop))
    #expect((stopped.phase) == (.stopped), "the session is stopped")

    let staleAfterStop = stopped.apply(pipelineEvent: delivery(.endOfTrack, playRequestID: 100))
    #expect((staleAfterStop.isEmpty) == true, "a pipeline event after stop with nothing current is ignored")
    #expect((stopped.phase) == (.stopped), "stop is never moved back to idle by a late pipeline event")
}
