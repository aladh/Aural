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

        let clearedTrackSeekID = UUID(uuidString: "00000000-0000-0000-0000-00000000003B")!
        var clearedTrackSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &clearedTrackSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: clearedTrackSeekID,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: seekTiming,
                    startedAt: presentationDate
                ))
            )
        )
        let stoppedTiming = PlaybackTiming(position: 0, duration: 0, anchoredAt: presentationDate.addingTimeInterval(1))
        _ = PlaybackReducer.reduce(
            &clearedTrackSeek,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(EnginePlaybackSnapshot(
                    transport: .stopped,
                    trackURI: nil,
                    timing: stoppedTiming
                ))
            )
        )
        check.equal("a nil-track snapshot adopts the incoming timing", clearedTrackSeek.timing, stoppedTiming)
        check.nil_("a nil-track snapshot supersedes the pending seek", clearedTrackSeek.pendingCommands[.seek])

        let nilCurrentTrackSeekID = UUID(uuidString: "00000000-0000-0000-0000-00000000003C")!
        var nilCurrentTrackSeek = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            timing: priorSeekTiming
        )
        _ = PlaybackReducer.reduce(
            &nilCurrentTrackSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: nilCurrentTrackSeekID,
                    kind: .seek,
                    expectedTransport: nil,
                    expectedTiming: seekTiming,
                    startedAt: presentationDate
                ))
            )
        )
        _ = PlaybackReducer.reduce(
            &nilCurrentTrackSeek,
            envelope: presentationEnvelope(source: .user, event: .currentTrack(nil))
        )
        check.nil_("a nil current-track event supersedes a seek with no current URI", nilCurrentTrackSeek.pendingCommands[.seek])
        check.equal("a nil current-track event resets timing", nilCurrentTrackSeek.timing.position, 0)
        let afterNilCurrentTrack = nilCurrentTrackSeek
        let nilCurrentTrackFinish = PlaybackReducer.reduce(
            &nilCurrentTrackSeek,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: nilCurrentTrackSeekID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Seek was rejected")
                )
            )
        )
        check.check("a finish after a nil current-track event is rejected", !nilCurrentTrackFinish)
        check.equal("a nil current-track event cannot restore seek rollback timing", nilCurrentTrackSeek, afterNilCurrentTrack)

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

    check.suite("Play target optimism is reducer-owned") {
        let playID = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!
        let confirmedID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        let supersededID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let nilID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let acceptedID = UUID(uuidString: "00000000-0000-0000-0000-000000000044")!
        let rawID = UUID(uuidString: "00000000-0000-0000-0000-000000000045")!
        let trackA = CurrentTrack(
            uri: "spotify:track:a",
            title: "A",
            artist: "Artist",
            duration: 200,
            metadataSource: .catalog
        )
        let trackB = CurrentTrack(
            uri: "spotify:track:b",
            title: "B",
            artist: "Artist",
            duration: 180,
            metadataSource: .catalog
        )
        let optimisticTiming = PlaybackTiming(position: 0, duration: 180, anchoredAt: presentationDate)
        let laggingATiming = PlaybackTiming(position: 44, duration: 200, anchoredAt: presentationDate)

        func startPlay(
            _ state: inout PlaybackState,
            id: UUID,
            expected: CurrentTrack = trackB
        ) {
            _ = PlaybackReducer.reduce(
                &state,
                envelope: presentationEnvelope(
                    source: .command,
                    event: .commandStarted(PendingPlaybackCommand(
                        id: id,
                        kind: .transport,
                        expectedTransport: .playing,
                        expectedTiming: PlaybackTiming(
                            position: 0,
                            duration: expected.duration,
                            anchoredAt: presentationDate
                        ),
                        expectedTrack: expected,
                        startedAt: presentationDate
                    ))
                )
            )
        }

        var playingA = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&playingA, id: playID)
        check.equal("play presents the known target atomically", playingA.currentTrack, trackB)
        check.equal("play applies playing transport atomically", playingA.transport, .playing)
        check.equal("play applies target timing atomically", playingA.timing, optimisticTiming)
        check.equal(
            "play captures the exact pre-command presentation",
            playingA.pendingCommands[.transport]?.rollbackPresentation,
            PlaybackPresentationSnapshot(
                currentTrack: trackA,
                transport: .playing,
                timing: priorPlayingTiming
            )
        )

        _ = PlaybackReducer.reduce(
            &playingA,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: trackA.uri,
                    timing: laggingATiming
                ))
            )
        )
        check.equal("a lagging A snapshot keeps the optimistic B track", playingA.currentTrack, trackB)
        check.equal("a lagging A snapshot keeps B timing", playingA.timing, optimisticTiming)
        check.equal("a lagging A snapshot does not confirm B", playingA.pendingCommands[.transport]?.id, playID)
        check.nil_("a lagging A snapshot is not a confirmation", playingA.transportCommandResolution)

        _ = PlaybackReducer.reduce(
            &playingA,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: playID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not play that Spotify URI")
                )
            )
        )
        check.equal("a rejected play restores track A", playingA.currentTrack, trackA)
        check.equal("a rejected play restores playing", playingA.transport, .playing)
        check.equal("a rejected play restores exact prior timing", playingA.timing, priorPlayingTiming)
        check.nil_("a rejected play clears its pending command", playingA.pendingCommands[.transport])

        var confirmed = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&confirmed, id: confirmedID)
        _ = PlaybackReducer.reduce(
            &confirmed,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: trackB.uri,
                    timing: PlaybackTiming(position: 1, duration: 180, anchoredAt: presentationDate)
                ))
            )
        )
        check.equal("an authoritative B snapshot keeps B", confirmed.currentTrack?.uri, trackB.uri)
        check.nil_("an authoritative B snapshot confirms the command", confirmed.pendingCommands[.transport])
        check.equal(
            "an authoritative B snapshot records confirmation",
            confirmed.transportCommandResolution,
            .confirmed(confirmedID)
        )
        let afterB = confirmed
        let lateFailure = PlaybackReducer.reduce(
            &confirmed,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: confirmedID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not play that Spotify URI")
                )
            )
        )
        check.check("a late failure after B confirmation is rejected", !lateFailure)
        check.equal("a late failure after B confirmation does not roll back", confirmed, afterB)

        var superseded = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&superseded, id: supersededID)
        let trackCTiming = PlaybackTiming(position: 8, duration: 240, anchoredAt: presentationDate)
        _ = PlaybackReducer.reduce(
            &superseded,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: "spotify:track:c",
                    timing: trackCTiming
                ))
            )
        )
        check.equal("an unrelated C snapshot adopts C", superseded.currentTrack?.uri, "spotify:track:c")
        check.equal("an unrelated C snapshot adopts C timing", superseded.timing, trackCTiming)
        check.nil_("an unrelated C snapshot clears B rollback ownership", superseded.pendingCommands[.transport])
        check.equal(
            "an unrelated C snapshot records supersession",
            superseded.transportCommandResolution,
            .superseded(supersededID)
        )
        let afterC = superseded
        let supersededFinish = PlaybackReducer.reduce(
            &superseded,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(
                    id: supersededID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not play that Spotify URI")
                )
            )
        )
        check.check("a late finish after C supersession is rejected", !supersededFinish)
        check.equal("a late finish after C supersession leaves C", superseded, afterC)

        var cleared = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&cleared, id: nilID)
        _ = PlaybackReducer.reduce(
            &cleared,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(EnginePlaybackSnapshot(
                    transport: .stopped,
                    trackURI: nil,
                    timing: PlaybackTiming(anchoredAt: presentationDate)
                ))
            )
        )
        check.nil_("a nil snapshot clears the optimistic track", cleared.currentTrack)
        check.equal("a nil snapshot stops transport", cleared.transport, .stopped)
        check.nil_("a nil snapshot clears B rollback ownership", cleared.pendingCommands[.transport])
        check.equal(
            "a nil snapshot records supersession",
            cleared.transportCommandResolution,
            .superseded(nilID)
        )

        var accepted = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .paused,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        startPlay(&accepted, id: acceptedID)
        _ = PlaybackReducer.reduce(
            &accepted,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandFinished(id: acceptedID, accepted: true, notice: nil)
            )
        )
        check.equal("an accepted play keeps the known target", accepted.currentTrack, trackB)
        check.equal("an accepted play keeps playing", accepted.transport, .playing)
        check.equal("an accepted play keeps target timing", accepted.timing, optimisticTiming)
        check.nil_("an accepted play clears its pending command", accepted.pendingCommands[.transport])

        var raw = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .paused,
            currentTrack: trackA,
            timing: priorPlayingTiming
        )
        _ = PlaybackReducer.reduce(
            &raw,
            envelope: presentationEnvelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: rawID,
                    kind: .transport,
                    expectedTransport: .playing,
                    startedAt: presentationDate
                ))
            )
        )
        check.equal("a raw play does not invent a target track", raw.currentTrack, trackA)
        check.equal("a raw play still applies playing", raw.transport, .playing)
        check.nil_("a raw play has no presentation rollback", raw.pendingCommands[.transport]?.rollbackPresentation)
        _ = PlaybackReducer.reduce(
            &raw,
            envelope: presentationEnvelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: trackA.uri,
                    timing: laggingATiming
                ))
            )
        )
        check.nil_(
            "a raw play is still confirmed by matching transport",
            raw.pendingCommands[.transport]
        )
    }
}
