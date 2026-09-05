import Foundation
import SpottyDomain
import Testing

private let unavailableTraceDate = Date(timeIntervalSince1970: 1_800_000_000)

private func unavailableEnvelope(
    account: UInt64 = 1,
    engine: UInt64 = 1,
    revision: UInt64? = nil,
    source: PlaybackEventSource = .enginePlayback,
    event: PlaybackEvent
) -> PlaybackEventEnvelope {
    PlaybackEventEnvelope(
        accountEpoch: account,
        engineEpoch: engine,
        source: source,
        revision: revision,
        receivedAt: unavailableTraceDate,
        event: event
    )
}

private func unavailableSnapshot(_ uri: String?, flagged: Bool = true) -> PlaybackEvent {
    .enginePlayback(
        EnginePlaybackSnapshot(
            transport: uri == nil ? .stopped : .paused,
            trackURI: uri,
            timing: PlaybackTiming(anchoredAt: unavailableTraceDate),
            trackUnavailable: flagged
        )
    )
}

private func reduceUnavailableCommand(
    _ state: inout PlaybackState,
    id: UUID,
    targetURI: String
) {
    _ = PlaybackReducer.reduce(
        &state,
        envelope: unavailableEnvelope(
            source: .command,
            event: .commandStarted(
                PendingPlaybackCommand(
                    id: id,
                    kind: .transport,
                    expectedTransport: .playing,
                    expectedTrack: CurrentTrack(uri: targetURI),
                    startedAt: unavailableTraceDate
                ))
        )
    )
}

@Suite("Playback Unavailable")
struct PlaybackUnavailableTests {
    @Test
    func testAcceptedLocalUnavailableSampleSetsActionableNotice() {
        let currentURI = "spotify:track:unavailable"
        let local = PlaybackDevice(id: "local", name: "Spotty", type: "computer", isActive: true)
        var state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: .local(local),
            transport: .playing,
            currentTrack: CurrentTrack(uri: currentURI)
        )

        #expect(
            PlaybackReducer.reduce(
                &state,
                envelope: unavailableEnvelope(
                    revision: 1,
                    event: unavailableSnapshot(currentURI)
                )
            ),
            "a current local unavailable sample is accepted"
        )
        #expect(
            (state.notice?.message) == (PlaybackNotice.trackUnavailableMessage),
            "an accepted unavailable sample uses the privacy-safe actionable message"
        )

        let afterAccepted = state
        #expect(
            (!PlaybackReducer.reduce(
                &state,
                envelope: unavailableEnvelope(
                    revision: 1,
                    event: unavailableSnapshot(currentURI)
                )
            )) == true,
            "a duplicate unavailable revision is rejected"
        )
        #expect((state) == (afterAccepted), "a stale unavailable sample is inert")

        #expect(
            (!PlaybackReducer.reduce(
                &state,
                envelope: unavailableEnvelope(
                    account: 0,
                    engine: 99,
                    revision: 2,
                    event: unavailableSnapshot(currentURI)
                )
            )) == true,
            "an unavailable sample from an old account is rejected before engine adoption"
        )
        #expect((state) == (afterAccepted), "an old account unavailable sample cannot mutate state")

        #expect(
            (!PlaybackReducer.reduce(
                &state,
                envelope: unavailableEnvelope(
                    account: 1,
                    engine: 0,
                    revision: 2,
                    event: unavailableSnapshot(currentURI)
                )
            )) == true,
            "an unavailable sample from an old engine generation is rejected"
        )
        #expect((state) == (afterAccepted), "an old engine unavailable sample cannot mutate state")
    }

    @Test
    func testUnavailableSampleCannotReplaceAnOptimisticPlayTarget() {
        let oldURI = "spotify:track:old"
        let targetURI = "spotify:track:target"
        let unrelatedURI = "spotify:track:unrelated"
        let local = PlaybackDevice(id: "local", name: "Spotty", type: "computer", isActive: true)

        var staleFailure = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: .local(local),
            transport: .playing,
            currentTrack: CurrentTrack(uri: oldURI)
        )
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
        reduceUnavailableCommand(&staleFailure, id: commandID, targetURI: targetURI)

        let beforeStaleFailure = staleFailure
        #expect(
            (!PlaybackReducer.reduce(
                &staleFailure,
                envelope: unavailableEnvelope(
                    revision: 1,
                    event: unavailableSnapshot(oldURI)
                )
            )) == true,
            "a failed old URI is rejected while a newer play target is pending"
        )
        #expect((staleFailure) == (beforeStaleFailure), "a stale failed URI cannot replace the optimistic target")

        #expect(
            PlaybackReducer.reduce(
                &staleFailure,
                envelope: unavailableEnvelope(
                    revision: 2,
                    event: unavailableSnapshot(targetURI)
                )
            ),
            "a failed optimistic target is accepted"
        )
        #expect((staleFailure.currentTrack?.uri) == (targetURI), "the target remains current")
        #expect(
            (staleFailure.notice?.message) == (PlaybackNotice.trackUnavailableMessage),
            "the matching target failure is surfaced"
        )

        var unrelatedFailure = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: .local(local),
            transport: .playing,
            currentTrack: CurrentTrack(uri: oldURI)
        )
        let unrelatedCommandID = UUID(uuidString: "00000000-0000-0000-0000-000000000092")!
        reduceUnavailableCommand(&unrelatedFailure, id: unrelatedCommandID, targetURI: targetURI)

        #expect(
            (!PlaybackReducer.reduce(
                &unrelatedFailure,
                envelope: unavailableEnvelope(
                    revision: 1,
                    event: unavailableSnapshot(unrelatedURI)
                )
            )) == true,
            "an unrelated failed URI is rejected while a newer play target is pending"
        )
        #expect(
            (unrelatedFailure.currentTrack?.uri) == (targetURI),
            "an unrelated failed URI leaves the optimistic target visible"
        )
        #expect((unrelatedFailure.notice) == nil, "an unrelated failed URI does not create a notice")
    }

    @Test
    func testUnavailableSampleCanIntroduceAConcreteTrackWithoutExistingPresentation() {
        let uri = "spotify:track:first-failure"
        let local = PlaybackDevice(id: "local", name: "Spotty", type: "computer", isActive: true)
        var state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: .local(local)
        )

        #expect(
            PlaybackReducer.reduce(
                &state,
                envelope: unavailableEnvelope(
                    revision: 1,
                    event: unavailableSnapshot(uri)
                )
            ),
            "a first concrete unavailable track is accepted"
        )
        #expect((state.currentTrack?.uri) == (uri), "the failed track identity remains available for retry")
        #expect(
            (state.notice?.message) == (PlaybackNotice.trackUnavailableMessage),
            "a first concrete local failure is actionable"
        )

        var emptyState = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: .local(local),
            currentTrack: CurrentTrack(uri: uri)
        )
        #expect(
            PlaybackReducer.reduce(
                &emptyState,
                envelope: unavailableEnvelope(
                    revision: 1,
                    event: unavailableSnapshot(nil)
                )
            ),
            "an empty identity snapshot is still a valid playback update"
        )
        #expect((emptyState.currentTrack) == nil, "an empty identity clears the current track")
        #expect((emptyState.notice) == nil, "an empty identity cannot create a failure notice")
    }
}
