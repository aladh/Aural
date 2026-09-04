import Testing
import SpottyDomain
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

@Test
func testPlaybackCommandLifecycle() {
    do {
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
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: transportID,
                        kind: .transport,
                        expectedTransport: .playing,
                        expectedTiming: timing,
                        expectedTrack: track,
                        startedAt: lifecycleDate
                    ))
            )
        )
        #expect(
            (state.pendingCommands[.transport]?.expectedTransport) == (Optional(PlaybackTransportState.playing)),
            "transport records expected playback")
        #expect(
            (state.pendingCommands[.transport]?.expectedTiming) == (Optional(timing)),
            "transport records expected timing")
        #expect(
            (state.pendingCommands[.transport]?.expectedTrack) == (Optional(track)), "transport records expected track")

        _ = PlaybackReducer.reduce(
            &state,
            envelope: lifecycleEnvelope(
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: optionsID,
                        kind: .options,
                        expectedTransport: nil,
                        expectedShuffle: false,
                        expectedRepeatFlags: repeatFlags,
                        startedAt: lifecycleDate
                    ))
            )
        )
        #expect(
            (state.pendingCommands[.options]?.expectedShuffle) == (Optional(false)), "options records expected shuffle")
        #expect(
            (state.pendingCommands[.options]?.expectedRepeatFlags) == (Optional(repeatFlags)),
            "options records expected repeat flags")
        #expect(
            (state.pendingCommands[.transport]?.id) == (transportID),
            "an options command leaves the transport command pending")

        _ = PlaybackReducer.reduce(
            &state,
            envelope: lifecycleEnvelope(
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: transferID,
                        kind: .transfer,
                        expectedTransport: nil,
                        expectedOwner: owner,
                        startedAt: lifecycleDate
                    ))
            )
        )
        #expect(
            (state.pendingCommands[.transfer]?.expectedOwner) == (Optional(owner)), "transfer records expected owner")
        #expect((state.pendingCommands.count) == (3), "typed expected fields stay on their command kinds")
    }

    do {
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
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: pauseID,
                        kind: .transport,
                        expectedTransport: .paused,
                        startedAt: lifecycleDate
                    ))
            )
        )
        #expect((state.transport) == (.paused), "pause applies optimistic paused transport")

        let unknown = PlaybackReducer.reduce(
            &state,
            envelope: lifecycleEnvelope(
                event: .commandFinished(id: otherID, accepted: false, notice: nil)
            )
        )
        #expect((!unknown) == true, "a mismatched cancel id is rejected")
        #expect((state.transport) == (.paused), "a mismatched cancel leaves optimistic pause")
        #expect((state.pendingCommands[.transport]?.id) == (pauseID), "a mismatched cancel leaves the pending command")

        _ = PlaybackReducer.reduce(
            &state,
            envelope: lifecycleEnvelope(
                event: .commandFinished(id: pauseID, accepted: false, notice: nil)
            )
        )
        #expect((state.transport) == (.playing), "ordinary cancellation restores the captured transport")
        #expect((state.timing) == (priorTiming), "ordinary cancellation restores the captured timing")
        #expect((state.pendingCommands[.transport]) == nil, "ordinary cancellation clears the pending command")
        #expect((state.notice) == (notice), "ordinary cancellation does not replace an unrelated notice")

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
        #expect((consumeOnly) == true, "a confirmed cancel consumes the resolution")
        #expect((confirmed.transport) == (.paused), "a confirmed cancel does not restore transport")
        #expect(
            (confirmed.transportCommandResolutions.isEmpty) == true, "a confirmed cancel does not leave a resolution")
    }
}
