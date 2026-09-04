import AuralDomain

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

func runAudioPlaybackSessionChecks(_ check: CheckRunner) {
    check.suite("Audio playback session") {
        checkStaleGeneration(check)
        checkNewerGenerationTearsDownLivePipeline(check)
        checkNewerGenerationCancelsHeldPreload(check)
        checkLoadStopsAnyLivePhaseNotOnlyPlaying(check)
        checkPreloadReuse(check)
        checkPreloadOverwriteCancelsThePrevious(check)
        checkSeekClamp(check)
        checkLoadingPhaseHonorsTransportCommands(check)
        checkTimeToPreloadNextOnce(check)
        checkEndOfTrackResetsToIdle(check)
        checkFailedReportsUnavailable(check)
        checkReportsCarryCurrentIdentity(check)
        checkPlayPauseWhenIdleAreNoOps(check)
        checkPipelineEventsAreScopedToCurrent(check)
    }
}

private func checkStaleGeneration(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 5)
    let stale = command(generation: 3, kind: .play)
    let effects = session.apply(stale)
    check.equal("a stale generation is ignored", effects, [.ignoreStale(stale)])
    check.equal("the session generation is unchanged", session.sessionGeneration, 5)
    check.equal("the phase is unchanged", session.phase, .idle)
}

private func checkNewerGenerationTearsDownLivePipeline(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    _ = session.apply(pipelineEvent: delivery(.playing, playRequestID: 100))
    check.equal("the session is playing before the reset", session.phase, .playing(playRequestID: 100))

    let load = command(generation: 2, playRequestID: 200, kind: .load, fileID: fileB, startPlaying: true)
    let effects = session.apply(load)

    check.equal(
        "a newer generation stops a live pipeline before loading",
        effects,
        [
            .stop,
            .beginLoad(session.current!, startPlaying: true, positionMs: 0, reusingPreload: false),
        ]
    )
    check.equal("the session generation is adopted", session.sessionGeneration, 2)
}

private func checkNewerGenerationCancelsHeldPreload(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(generation: 1, playRequestID: 90, kind: .preload, fileID: fileB))
    check.notNil("a preload is held before the reset", session.preloaded)

    let load = command(generation: 2, playRequestID: 200, kind: .load, fileID: fileA, startPlaying: true)
    let effects = session.apply(load)

    check.equal(
        "a dropped preload is cancelled before the reset load runs",
        effects,
        [
            .cancelPreload(playRequestID: 90),
            .beginLoad(session.current!, startPlaying: true, positionMs: 0, reusingPreload: false),
        ]
    )
    check.nil_("the stale preload is dropped by the reset", session.preloaded)
}

private func checkLoadStopsAnyLivePhaseNotOnlyPlaying(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    check.equal("the first load is still loading", session.phase, .loading(playRequestID: 100))

    let secondLoad = command(playRequestID: 101, kind: .load, trackURI: "spotify:track:two", fileID: fileB)
    let effects = session.apply(secondLoad)

    check.equal(
        "a stop effect precedes beginLoad when the previous load was still loading",
        effects,
        [
            .stop,
            .beginLoad(session.current!, startPlaying: true, positionMs: 0, reusingPreload: false),
        ]
    )
    check.equal("the phase moves to loading the new request", session.phase, .loading(playRequestID: 101))
}

private func checkPreloadReuse(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    _ = session.apply(pipelineEvent: delivery(.playing, playRequestID: 100))

    let preload = session.apply(
        command(playRequestID: 101, kind: .preload, trackURI: "spotify:track:two", fileID: fileB)
    )
    check.notNil("the preloaded track is held", session.preloaded)
    let emitsBeginPreload = preload.contains { effect in
        if case .beginPreload = effect { return true }
        return false
    }
    check.check("beginPreload is emitted", emitsBeginPreload)

    let load = command(
        playRequestID: 102, kind: .load, trackURI: "spotify:track:two", fileID: fileB, startPlaying: true
    )
    let effects = session.apply(load)

    check.equal(
        "a load matching the preloaded file id reuses it without cancelling it",
        effects,
        [
            .stop,
            .beginLoad(session.current!, startPlaying: true, positionMs: 0, reusingPreload: true),
        ]
    )
    check.nil_("the consumed preload slot is cleared", session.preloaded)
}

private func checkPreloadOverwriteCancelsThePrevious(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    let firstPreload = session.apply(
        command(playRequestID: 100, kind: .preload, trackURI: "spotify:track:one", fileID: fileA)
    )
    check.equal(
        "the first preload has nothing to cancel",
        firstPreload,
        [.beginPreload(session.preloaded!)]
    )

    let secondPreload = session.apply(
        command(playRequestID: 101, kind: .preload, trackURI: "spotify:track:two", fileID: fileB)
    )
    check.equal(
        "overwriting a held preload cancels it before starting the new one",
        secondPreload,
        [
            .cancelPreload(playRequestID: 100),
            .beginPreload(session.preloaded!),
        ]
    )
}

private func checkSeekClamp(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: false, durationMs: 10_000)
    )
    _ = session.apply(pipelineEvent: delivery(.paused, playRequestID: 100))

    let withinBounds = session.apply(command(playRequestID: 100, kind: .seek, positionMs: 4_000))
    check.equal("a seek within duration passes through", withinBounds, [.seek(positionMs: 4_000)])

    let pastEnd = session.apply(command(playRequestID: 100, kind: .seek, positionMs: 50_000))
    check.equal("a seek past the known duration clamps to it", pastEnd, [.seek(positionMs: 10_000)])
    check.equal("the clamped position is retained", session.positionMs, 10_000)
}

private func checkLoadingPhaseHonorsTransportCommands(_ check: CheckRunner) {
    var pauseDuringLoad = AudioPlaybackSession(sessionGeneration: 1)
    _ = pauseDuringLoad.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true)
    )
    let pauseEffects = pauseDuringLoad.apply(command(playRequestID: 100, kind: .pause))
    check.equal("pause during loading is queued for the pipeline", pauseEffects, [.pause])
    check.equal(
        "pause during loading does not force a phase jump",
        pauseDuringLoad.phase,
        .loading(playRequestID: 100)
    )

    var playDuringLoad = AudioPlaybackSession(sessionGeneration: 1)
    _ = playDuringLoad.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: false)
    )
    let playEffects = playDuringLoad.apply(command(playRequestID: 100, kind: .play))
    check.equal("play during loading is queued for the pipeline", playEffects, [.play])
    check.equal(
        "play during loading does not force a phase jump",
        playDuringLoad.phase,
        .loading(playRequestID: 100)
    )

    var seekDuringLoad = AudioPlaybackSession(sessionGeneration: 1)
    _ = seekDuringLoad.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true, durationMs: 10_000)
    )
    let seekEffects = seekDuringLoad.apply(command(playRequestID: 100, kind: .seek, positionMs: 3_000))
    check.equal("seek during loading is queued for the pipeline", seekEffects, [.seek(positionMs: 3_000)])
    check.equal(
        "seek during loading does not force a phase jump",
        seekDuringLoad.phase,
        .loading(playRequestID: 100)
    )
    check.equal("the position is updated immediately", seekDuringLoad.positionMs, 3_000)
}

private func checkTimeToPreloadNextOnce(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true, durationMs: 40_000)
    )
    _ = session.apply(pipelineEvent: delivery(.playing, playRequestID: 100))

    let beforeWindow = session.apply(pipelineEvent: delivery(.position(5_000), playRequestID: 100))
    check.equal("no preload-next report before the window", beforeWindow.count, 1)

    let enteringWindow = session.apply(pipelineEvent: delivery(.position(12_000), playRequestID: 100))
    check.equal(
        "entering the 30s window reports timeToPreloadNext once",
        enteringWindow,
        [
            .report(
                AudioReport(
                    sessionGeneration: 1, playRequestID: 100, kind: .position, positionMs: 12_000, durationMs: 40_000
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
        ]
    )

    let stillWithinWindow = session.apply(pipelineEvent: delivery(.position(13_000), playRequestID: 100))
    check.equal("it does not repeat for the same load", stillWithinWindow.count, 1)
}

private func checkEndOfTrackResetsToIdle(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true, durationMs: 5_000)
    )
    _ = session.apply(pipelineEvent: delivery(.playing, playRequestID: 100))

    let effects = session.apply(pipelineEvent: delivery(.endOfTrack, playRequestID: 100))

    check.equal(
        "endOfTrack reports and resets to idle",
        effects,
        [
            .report(
                AudioReport(
                    sessionGeneration: 1, playRequestID: 100, kind: .endOfTrack, positionMs: 5_000, durationMs: 5_000
                )
            )
        ]
    )
    check.equal("the phase is idle", session.phase, .idle)
    check.nil_("current is cleared", session.current)
    check.equal("position resets", session.positionMs, 0)
}

private func checkFailedReportsUnavailable(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    _ = session.apply(pipelineEvent: delivery(.playing, playRequestID: 100))

    let effects = session.apply(pipelineEvent: delivery(.failed(.decodeFailed), playRequestID: 100))

    check.equal(
        "failed reports unavailable",
        effects,
        [
            .report(
                AudioReport(sessionGeneration: 1, playRequestID: 100, kind: .unavailable, positionMs: 0, durationMs: 0)
            )
        ]
    )
    check.equal("the phase moves to stopped", session.phase, .stopped)
    check.nil_("current is cleared", session.current)
}

private func checkReportsCarryCurrentIdentity(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 7)
    _ = session.apply(command(generation: 7, playRequestID: 55, kind: .load, fileID: fileA, startPlaying: true))
    let effects = session.apply(pipelineEvent: delivery(.playing, generation: 7, playRequestID: 55))

    check.equal(
        "a report stamps the session generation and the current play request id",
        effects,
        [.report(AudioReport(sessionGeneration: 7, playRequestID: 55, kind: .playing, positionMs: 0, durationMs: 0))]
    )
}

private func checkPlayPauseWhenIdleAreNoOps(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)

    check.check("play emits nothing when idle", session.apply(command(kind: .play)).isEmpty)
    check.check("pause emits nothing when idle", session.apply(command(kind: .pause)).isEmpty)
    check.check("seek emits nothing when idle", session.apply(command(kind: .seek)).isEmpty)
    check.check("stop emits nothing when idle", session.apply(command(kind: .stop)).isEmpty)
    check.equal("the phase stays idle", session.phase, .idle)
}

private func checkPipelineEventsAreScopedToCurrent(_ check: CheckRunner) {
    var noCurrent = AudioPlaybackSession(sessionGeneration: 1)
    let ignoredWithNothingLoaded = noCurrent.apply(pipelineEvent: delivery(.endOfTrack, playRequestID: 100))
    check.check("every pipeline event is ignored when nothing is loaded", ignoredWithNothingLoaded.isEmpty)

    var superseded = AudioPlaybackSession(sessionGeneration: 1)
    _ = superseded.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    _ = superseded.apply(pipelineEvent: delivery(.playing, playRequestID: 100))
    _ = superseded.apply(command(playRequestID: 101, kind: .load, trackURI: "spotify:track:two", fileID: fileB))
    check.equal("the second load is current", superseded.current?.playRequestID, 101)

    let staleEndOfTrack = superseded.apply(pipelineEvent: delivery(.endOfTrack, playRequestID: 100))
    check.equal(
        "a stale playRequestID is ignored instead of applied",
        staleEndOfTrack,
        [.ignoreStalePipelineEvent(delivery(.endOfTrack, playRequestID: 100))]
    )
    check.notEqual("the current load is untouched", superseded.phase, .idle)
    check.equal("the current identity is unchanged", superseded.current?.playRequestID, 101)

    var stopped = AudioPlaybackSession(sessionGeneration: 1)
    _ = stopped.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    _ = stopped.apply(pipelineEvent: delivery(.playing, playRequestID: 100))
    _ = stopped.apply(command(playRequestID: 100, kind: .stop))
    check.equal("the session is stopped", stopped.phase, .stopped)

    let staleAfterStop = stopped.apply(pipelineEvent: delivery(.endOfTrack, playRequestID: 100))
    check.check("a pipeline event after stop with nothing current is ignored", staleAfterStop.isEmpty)
    check.equal("stop is never moved back to idle by a late pipeline event", stopped.phase, .stopped)
}
