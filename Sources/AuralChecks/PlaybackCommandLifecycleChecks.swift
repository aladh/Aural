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
                    expectedOwner: owner,
                    startedAt: lifecycleDate
                ))
            )
        )
        check.equal("transfer records expected owner", state.pendingCommands[.transfer]?.expectedOwner, Optional(owner))
        check.equal("typed expected fields stay on their command kinds", state.pendingCommands.count, 3)
    }
}
