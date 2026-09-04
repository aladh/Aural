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

func runAudioPlaybackSessionChecks(_ check: CheckRunner) {
    check.suite("Audio playback session") {
        checkStaleGeneration(check)
        checkNewerGenerationResets(check)
        checkLoadOrderingAndStopFirst(check)
        checkPreloadReuse(check)
        checkSeekClamp(check)
        checkTimeToPreloadNextOnce(check)
        checkEndOfTrackResetsToIdle(check)
        checkFailedReportsUnavailable(check)
        checkReportsCarryCurrentIdentity(check)
        checkPlayPauseWhenIdleAreNoOps(check)
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

private func checkNewerGenerationResets(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(generation: 1, kind: .preload, fileID: fileB))
    check.notNil("a preload is held before the reset", session.preloaded)

    let load = command(generation: 2, playRequestID: 200, kind: .load, fileID: fileA, startPlaying: true)
    let effects = session.apply(load)

    check.equal("a newer generation is adopted", session.sessionGeneration, 2)
    check.nil_("the stale preload is dropped by the reset", session.preloaded)
    check.equal(
        "the load still runs against the reset state",
        effects,
        [.beginLoad(session.current!, startPlaying: true, positionMs: 0, reusingPreload: false)]
    )
}

private func checkLoadOrderingAndStopFirst(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true))
    _ = session.apply(pipelineEvent: .playing)
    check.equal("the session is playing before the next load", session.phase, .playing(playRequestID: 100))

    let secondLoad = command(playRequestID: 101, kind: .load, trackURI: "spotify:track:two", fileID: fileB)
    let effects = session.apply(secondLoad)

    check.equal(
        "a stop effect precedes beginLoad when a track was playing",
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
    _ = session.apply(pipelineEvent: .playing)

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
        "a load matching the preloaded file id reuses it",
        effects,
        [
            .stop,
            .beginLoad(session.current!, startPlaying: true, positionMs: 0, reusingPreload: true),
        ]
    )
    check.nil_("the consumed preload slot is cleared", session.preloaded)
}

private func checkSeekClamp(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: false, durationMs: 10_000)
    )
    _ = session.apply(pipelineEvent: .paused)

    let withinBounds = session.apply(command(playRequestID: 100, kind: .seek, positionMs: 4_000))
    check.equal("a seek within duration passes through", withinBounds, [.seek(positionMs: 4_000)])

    let pastEnd = session.apply(command(playRequestID: 100, kind: .seek, positionMs: 50_000))
    check.equal("a seek past the known duration clamps to it", pastEnd, [.seek(positionMs: 10_000)])
    check.equal("the clamped position is retained", session.positionMs, 10_000)
}

private func checkTimeToPreloadNextOnce(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true, durationMs: 40_000)
    )
    _ = session.apply(pipelineEvent: .playing)

    let beforeWindow = session.apply(pipelineEvent: .position(5_000))
    check.equal("no preload-next report before the window", beforeWindow.count, 1)

    let enteringWindow = session.apply(pipelineEvent: .position(12_000))
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

    let stillWithinWindow = session.apply(pipelineEvent: .position(13_000))
    check.equal("it does not repeat for the same load", stillWithinWindow.count, 1)
}

private func checkEndOfTrackResetsToIdle(_ check: CheckRunner) {
    var session = AudioPlaybackSession(sessionGeneration: 1)
    _ = session.apply(
        command(playRequestID: 100, kind: .load, fileID: fileA, startPlaying: true, durationMs: 5_000)
    )
    _ = session.apply(pipelineEvent: .playing)

    let effects = session.apply(pipelineEvent: .endOfTrack)

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
    _ = session.apply(pipelineEvent: .playing)

    let effects = session.apply(pipelineEvent: .failed("CDN 403"))

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
    let effects = session.apply(pipelineEvent: .playing)

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
