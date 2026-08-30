import AuralDomain
import Foundation

private let lifecycleDate = Date(timeIntervalSince1970: 1_800_000_000)

private func lifecycleEnvelope(event: PlaybackEvent) -> PlaybackEventEnvelope {
    PlaybackEventEnvelope(
        accountEpoch: 1,
        engineEpoch: 1,
        source: .command,
        revision: nil,
        receivedAt: lifecycleDate,
        event: event
    )
}

func runPlaybackCommandLifecycleChecks(_ check: CheckRunner) {
    check.suite("Typed expected fields on command start") {
        let transportID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let optionsID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
        let transferID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
        let track = CurrentTrack(
            uri: "spotify:track:b",
            title: "B",
            artist: "Artist",
            duration: 180,
            metadataSource: .catalog
        )
        let timing = PlaybackTiming(position: 0, duration: 180, anchoredAt: lifecycleDate)
        let owner = PlaybackOwner.uncertain(
            PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker")
        )
        let repeatFlags = RepeatMode.context.flags

        var state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .paused,
            currentTrack: CurrentTrack(
                uri: "spotify:track:a",
                title: "A",
                artist: "Artist",
                duration: 200,
                metadataSource: .catalog
            )
        )

        _ = PlaybackReducer.reduce(
            &state,
            envelope: lifecycleEnvelope(
                event: .commandStarted(PendingPlaybackCommand(
                    id: transportID,
                    kind: .transport,
                    expectedTransport: .playing,
                    expectedTiming: timing,
                    expectedTrack: track,
                    startedAt: lifecycleDate
                ))
            )
        )
        check.equal("transport records expected playback", state.pendingCommands[.transport]?.expectedTransport, Optional(PlaybackTransportState.playing))
        check.equal("transport records expected timing", state.pendingCommands[.transport]?.expectedTiming, Optional(timing))
        check.equal("transport records expected track", state.pendingCommands[.transport]?.expectedTrack, Optional(track))

        _ = PlaybackReducer.reduce(
            &state,
            envelope: lifecycleEnvelope(
                event: .commandStarted(PendingPlaybackCommand(
                    id: optionsID,
                    kind: .options,
                    expectedTransport: nil,
                    expectedShuffle: false,
                    expectedRepeatFlags: repeatFlags,
                    startedAt: lifecycleDate
                ))
            )
        )
        check.equal("options records expected shuffle", state.pendingCommands[.options]?.expectedShuffle, Optional(false))
        check.equal("options records expected repeat flags", state.pendingCommands[.options]?.expectedRepeatFlags, Optional(repeatFlags))
        check.equal("an options command leaves the transport command pending", state.pendingCommands[.transport]?.id, transportID)

        _ = PlaybackReducer.reduce(
            &state,
            envelope: lifecycleEnvelope(
                event: .commandStarted(PendingPlaybackCommand(
                    id: transferID,
                    kind: .transfer,
                    expectedTransport: nil,
                    expectedOwner: owner,
                    startedAt: lifecycleDate
                ))
            )
        )
        check.equal("transfer records expected owner", state.pendingCommands[.transfer]?.expectedOwner, Optional(owner))
        check.equal("typed expected fields stay on their command kinds", state.pendingCommands.count, 3)
    }

    check.suite("Ordinary cancellation rolls back only the matching command") {
        let pauseID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        let priorTiming = PlaybackTiming(position: 40, duration: 200, anchoredAt: lifecycleDate)
        let notice = PlaybackNotice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!,
            message: "Unrelated notice"
        )
        var state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(
                uri: "spotify:track:a",
                title: "A",
                artist: "Artist",
                duration: 200,
                metadataSource: .catalog
            ),
            timing: priorTiming,
            notice: notice
        )

        _ = PlaybackReducer.reduce(
            &state,
            envelope: lifecycleEnvelope(
                event: .commandStarted(PendingPlaybackCommand(
                    id: pauseID,
                    kind: .transport,
                    expectedTransport: .paused,
                    startedAt: lifecycleDate
                ))
            )
        )
        check.equal("pause applies optimistic paused transport", state.transport, .paused)

        let unknown = PlaybackReducer.reduce(
            &state,
            envelope: lifecycleEnvelope(
                event: .commandFinished(id: otherID, accepted: false, notice: nil)
            )
        )
        check.check("a mismatched cancel id is rejected", !unknown)
        check.equal("a mismatched cancel leaves optimistic pause", state.transport, .paused)
        check.equal("a mismatched cancel leaves the pending command", state.pendingCommands[.transport]?.id, pauseID)

        _ = PlaybackReducer.reduce(
            &state,
            envelope: lifecycleEnvelope(
                event: .commandFinished(id: pauseID, accepted: false, notice: nil)
            )
        )
        check.equal("ordinary cancellation restores the captured transport", state.transport, .playing)
        check.equal("ordinary cancellation restores the captured timing", state.timing, priorTiming)
        check.nil_("ordinary cancellation clears the pending command", state.pendingCommands[.transport])
        check.equal("ordinary cancellation does not replace an unrelated notice", state.notice, notice)

        let confirmedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!
        var confirmed = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .paused,
            transportCommandResolutions: [confirmedID: .confirmed]
        )
        let consumeOnly = PlaybackReducer.reduce(
            &confirmed,
            envelope: lifecycleEnvelope(
                event: .commandFinished(id: confirmedID, accepted: false, notice: nil)
            )
        )
        check.check("a confirmed cancel consumes the resolution", consumeOnly)
        check.equal("a confirmed cancel does not restore transport", confirmed.transport, .paused)
        check.check("a confirmed cancel does not leave a resolution", confirmed.transportCommandResolutions.isEmpty)
    }
}
