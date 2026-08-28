import AuralDomain
import Foundation

private let presentationDate = Date(timeIntervalSince1970: 1_000_000)

private func presentationEnvelope(
    account: UInt64 = 1,
    engine: UInt64 = 1,
    source: PlaybackEventSource,
    revision: UInt64? = nil,
    event: PlaybackEvent
) -> PlaybackEventEnvelope {
    PlaybackEventEnvelope(
        accountEpoch: account,
        engineEpoch: engine,
        source: source,
        revision: revision,
        receivedAt: presentationDate,
        event: event
    )
}

func runPlaybackCommandPresentationChecks(_ check: CheckRunner) {
    let playingAnchor = presentationDate.addingTimeInterval(-10)
    let priorPlayingTiming = PlaybackTiming(position: 40, duration: 200, anchoredAt: playingAnchor)
    let frozenPauseTiming = PlaybackTiming(
        position: interpolatedPlaybackPosition(
            anchor: 40,
            anchoredAt: playingAnchor,
            now: presentationDate,
            isPlaying: true,
            duration: 200
        ),
        duration: 200,
        anchoredAt: presentationDate
    )
    let priorSeekTiming = PlaybackTiming(position: 12, duration: 200, anchoredAt: playingAnchor)
    let seekTiming = PlaybackTiming(position: 80, duration: 200, anchoredAt: presentationDate)

    check.suite("Pause and resume optimism is reducer-owned") {
        let pauseID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let resumeID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!

        check.equal("the pause freeze is the displayed playing position", frozenPauseTiming.position, 50)

        var pauseState = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorPlayingTiming
        )
        _ = PlaybackReducer.reduce(
            &pauseState,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: pauseID,
                    kind: .transport,
                    expectedTransport: .paused,
                    expectedTiming: frozenPauseTiming,
                    startedAt: presentationDate
                ))
            )
        )
        check.equal("pause applies paused transport atomically", pauseState.transport, .paused)
        check.equal("pause freezes timing at the displayed position", pauseState.timing, frozenPauseTiming)
        check.equal(
            "pause captures the pre-command transport for rollback",
            pauseState.pendingCommands[.transport]?.rollbackTransport,
            .playing
        )
        check.equal(
            "pause captures the pre-command timing for rollback",
            pauseState.pendingCommands[.transport]?.rollbackTiming,
            priorPlayingTiming
        )

        let afterOptimisticPause = pauseState
        _ = PlaybackReducer.reduce(
            &pauseState,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(id: pauseID, accepted: false, notice: PlaybackNotice(message: "Pause was rejected"))
            )
        )
        check.equal("a rejected pause restores the pre-command transport", pauseState.transport, .playing)
        check.equal("a rejected pause restores the exact pre-command timing", pauseState.timing, priorPlayingTiming)
        check.nil_("a rejected pause clears its pending command", pauseState.pendingCommands[.transport])
        check.check("a rejected pause is not a no-op relative to optimism", pauseState.timing != afterOptimisticPause.timing)

        let priorPausedTiming = PlaybackTiming(position: 50, duration: 200, anchoredAt: playingAnchor)
        let resumeTiming = PlaybackTiming(position: 50, duration: 200, anchoredAt: presentationDate)
        var resumeState = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .paused,
            timing: priorPausedTiming
        )
        _ = PlaybackReducer.reduce(
            &resumeState,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: resumeID,
                    kind: .transport,
                    expectedTransport: .playing,
                    expectedTiming: resumeTiming,
                    startedAt: presentationDate
                ))
            )
        )
        check.equal("resume applies playing transport atomically", resumeState.transport, .playing)
        check.equal("resume re-anchors timing from now without moving position", resumeState.timing, resumeTiming)
        _ = PlaybackReducer.reduce(
            &resumeState,
            envelope: presentationEnvelope(source: .command, event: .commandFinished(id: resumeID, accepted: true, notice: nil))
        )
        check.equal("an accepted resume keeps the re-anchored timing", resumeState.timing, resumeTiming)
        check.equal("an accepted resume keeps playing", resumeState.transport, .playing)
    }

    check.suite("Seek optimism holds until a matching sample") {
        let seekID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        let acceptedSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000033")!
        let staleSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000034")!
        let matchingSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000035")!
        let mismatchedSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000038")!
        let supersededSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000036")!
        let replacementSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000037")!

        var seekState = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &seekState,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: seekID,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: seekTiming,
                    startedAt: presentationDate
                ))
            )
        )
        check.equal("seek does not change transport", seekState.transport, .playing)
        check.equal("seek applies optimistic timing", seekState.timing, seekTiming)
        check.equal(
            "seek captures the pre-command timing for rollback",
            seekState.pendingCommands[.seek]?.rollbackTiming,
            priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &seekState,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(id: seekID, accepted: false, notice: PlaybackNotice(message: "Seek was rejected"))
            )
        )
        check.equal("a rejected seek restores the exact pre-command timing", seekState.timing, priorSeekTiming)
        check.nil_("a rejected seek clears its pending command", seekState.pendingCommands[.seek])

        var acceptedSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .paused,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &acceptedSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: acceptedSeekID,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: seekTiming,
                    startedAt: presentationDate
                ))
            )
        )
        _ = PlaybackReducer.reduce(
            &acceptedSeek,
            envelope: presentationEnvelope(source: .command, event: .commandFinished(id: acceptedSeekID, accepted: true, notice: nil))
        )
        check.equal("an accepted seek keeps the optimistic timing", acceptedSeek.timing, seekTiming)
        check.nil_("an accepted seek clears its pending command", acceptedSeek.pendingCommands[.seek])

        var mismatchedSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: "spotify:track:seek"),
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &mismatchedSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: mismatchedSeekID,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: seekTiming,
                    startedAt: presentationDate
                ))
            )
        )
        let laggingTiming = PlaybackTiming(position: 21, duration: 200, anchoredAt: presentationDate.addingTimeInterval(1))
        _ = PlaybackReducer.reduce(
            &mismatchedSeek,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: "spotify:track:seek",
                    timing: laggingTiming
                ))
            )
        )
        check.equal("a lagging engine snapshot cannot undo optimistic seek timing", mismatchedSeek.timing, seekTiming)
        check.equal("a lagging engine snapshot does not reconcile the pending seek", mismatchedSeek.pendingCommands[.seek]?.id, mismatchedSeekID)
        _ = PlaybackReducer.reduce(
            &mismatchedSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: mismatchedSeekID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        check.equal("a rejected seek after a lagging snapshot still rolls back", mismatchedSeek.timing, priorSeekTiming)

        var matchingSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: "spotify:track:seek"),
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &matchingSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: matchingSeekID,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: seekTiming,
                    startedAt: presentationDate
                ))
            )
        )
        let confirmedTiming = PlaybackTiming(position: 80, duration: 200, anchoredAt: presentationDate.addingTimeInterval(1))
        _ = PlaybackReducer.reduce(
            &matchingSeek,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: "spotify:track:seek",
                    timing: confirmedTiming
                ))
            )
        )
        check.equal("a matching engine snapshot adopts confirmed seek timing", matchingSeek.timing, confirmedTiming)
        check.nil_("a matching engine snapshot reconciles the pending seek", matchingSeek.pendingCommands[.seek])
        let afterConfirmedSeek = matchingSeek
        let confirmedFinish = PlaybackReducer.reduce(
            &matchingSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: matchingSeekID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        check.check("a finish after a matching seek snapshot is rejected", !confirmedFinish)
        check.equal("a matching snapshot prevents stale seek rollback", matchingSeek, afterConfirmedSeek)

        let trackSwitchSeekID = UUID(uuidString: "00000000-0000-0000-0000-000000000039")!
        var trackSwitchSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: "spotify:track:a"),
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &trackSwitchSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: trackSwitchSeekID,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: seekTiming,
                    startedAt: presentationDate
                ))
            )
        )
        let trackBTiming = PlaybackTiming(position: 0, duration: 180, anchoredAt: presentationDate.addingTimeInterval(1))
        _ = PlaybackReducer.reduce(
            &trackSwitchSeek,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: "spotify:track:b",
                    timing: trackBTiming
                ))
            )
        )
        check.equal("a newer track snapshot adopts the incoming timing", trackSwitchSeek.timing, trackBTiming)
        check.equal("a newer track snapshot replaces the current track", trackSwitchSeek.currentTrack?.uri, "spotify:track:b")
        check.nil_("a newer track snapshot supersedes the old pending seek", trackSwitchSeek.pendingCommands[.seek])
        let afterTrackSwitch = trackSwitchSeek
        let supersededByTrackFinish = PlaybackReducer.reduce(
            &trackSwitchSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: trackSwitchSeekID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        check.check("a finish after a track switch is rejected", !supersededByTrackFinish)
        check.equal("a track-switched seek cannot restore the previous track's timing", trackSwitchSeek, afterTrackSwitch)

        let currentTrackSwitchID = UUID(uuidString: "00000000-0000-0000-0000-00000000003A")!
        var currentTrackSwitch = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: "spotify:track:a"),
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &currentTrackSwitch,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: currentTrackSwitchID,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: seekTiming,
                    startedAt: presentationDate
                ))
            )
        )
        _ = PlaybackReducer.reduce(
            &currentTrackSwitch,
            envelope: presentationEnvelope(
                source: .user,
                event: .currentTrack(CurrentTrack(uri: "spotify:track:b"))
            )
        )
        check.equal("a current-track switch keeps the new track", currentTrackSwitch.currentTrack?.uri, "spotify:track:b")
        check.nil_("a current-track switch supersedes the old pending seek", currentTrackSwitch.pendingCommands[.seek])
        let afterCurrentTrackSwitch = currentTrackSwitch
        let currentTrackFinish = PlaybackReducer.reduce(
            &currentTrackSwitch,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: currentTrackSwitchID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        check.check("a finish after a current-track switch is rejected", !currentTrackFinish)
        check.equal("a current-track switch cannot restore the previous track's timing", currentTrackSwitch, afterCurrentTrackSwitch)

        var identitySeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &identitySeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: staleSeekID,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: seekTiming,
                    startedAt: presentationDate
                ))
            )
        )
        _ = PlaybackReducer.reduce(
            &identitySeek,
            envelope: presentationEnvelope(
                engine: 2,
                source: .engineConnection,
                revision: 1,
                event: .engineConnection(EngineConnectionSnapshot(
                    session: .recovering,
                    owner: .none,
                    localDeviceID: nil
                ))
            )
        )
        check.nil_("an engine-epoch bump drops the pending seek", identitySeek.pendingCommands[.seek])
        check.equal("an engine-epoch bump does not roll back seek timing", identitySeek.timing, seekTiming)
        let afterEngineBump = identitySeek
        let staleIdentityFinish = PlaybackReducer.reduce(
            &identitySeek,
            envelope: presentationEnvelope(
                engine: 1,
                source: .command,
                event: .commandFinished(
                    id: staleSeekID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        check.check("a captured-engine seek finish is rejected after an epoch bump", !staleIdentityFinish)
        check.equal("a stale-identity finish cannot roll back seek timing", identitySeek, afterEngineBump)

        var supersededSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &supersededSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: supersededSeekID,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: seekTiming,
                    startedAt: presentationDate
                ))
            )
        )
        let replacementTiming = PlaybackTiming(position: 90, duration: 200, anchoredAt: presentationDate.addingTimeInterval(1))
        _ = PlaybackReducer.reduce(
            &supersededSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: replacementSeekID,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: replacementTiming,
                    startedAt: presentationDate.addingTimeInterval(1)
                ))
            )
        )
        let afterReplacementSeek = supersededSeek
        let supersededFinish = PlaybackReducer.reduce(
            &supersededSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(id: supersededSeekID, accepted: false, notice: PlaybackNotice(message: "Seek was rejected"))
            )
        )
        check.check("a superseded seek finish is rejected", !supersededFinish)
        check.equal("a superseded seek finish cannot roll back the replacement", supersededSeek, afterReplacementSeek)
        check.equal("the replacement seek remains pending", supersededSeek.pendingCommands[.seek]?.id, replacementSeekID)
        check.equal("the replacement seek keeps its optimistic timing", supersededSeek.timing, replacementTiming)
        check.equal(
            "the replacement seek rolls back to the superseded optimistic timing",
            supersededSeek.pendingCommands[.seek]?.rollbackTiming,
            seekTiming
        )
    }
}
