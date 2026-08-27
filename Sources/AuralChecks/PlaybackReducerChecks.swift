import AuralDomain
import Foundation

private let traceDate = Date(timeIntervalSince1970: 1_000_000)

private func envelope(
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
        receivedAt: traceDate,
        event: event
    )
}

private func item(_ suffix: String, occurrence: Int = 0, provider: String = "web-api") -> PlaybackQueueItem {
    let uri = "spotify:track:\(suffix)"
    return PlaybackQueueItem(id: "\(occurrence)-\(provider)-\(uri)", uri: uri, provider: provider)
}

private func queue(
    _ entries: [PlaybackQueueItem],
    source: PlaybackQueueSource,
    completeness: PlaybackQueueCompleteness,
    revision: UInt64,
    contextURI: String? = nil
) -> PlaybackQueueSnapshot {
    PlaybackQueueSnapshot(
        entries: entries,
        source: source,
        completeness: completeness,
        revision: revision,
        receivedAt: traceDate.addingTimeInterval(TimeInterval(revision)),
        contextURI: contextURI
    )
}

func runPlaybackReducerChecks(_ check: CheckRunner) {
    check.suite("Playback reducer account and engine epochs") {
        let remote = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")
        var state = PlaybackState(
            accountEpoch: 4,
            engineEpoch: 7,
            session: .ready,
            owner: .remote(remote),
            transport: .paused,
            currentTrack: CurrentTrack(uri: "spotify:track:current", title: "Current")
        )

        let beforeStaleAccount = state
        let staleAccountAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(account: 3, engine: 99, source: .account, event: .session(.failed("stale")))
        )
        check.check("an old account callback is rejected", !staleAccountAccepted)
        check.equal("an old account callback cannot mutate state", state, beforeStaleAccount)

        let beforeStaleEngine = state
        let staleEngineAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(account: 4, engine: 6, source: .enginePlayback, event: .transport(.playing))
        )
        check.check("a pre-restart engine callback is rejected", !staleEngineAccepted)
        check.equal("a pre-restart engine callback cannot mutate state", state, beforeStaleEngine)

        let pendingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                account: 4,
                engine: 7,
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(id: pendingID, kind: .transport, expectedTransport: .playing, startedAt: traceDate))
            )
        )
        check.notNil("the characterization starts with a pending command", state.pendingCommands[.transport])

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(account: 4, engine: 8, source: .engineConnection, revision: 1, event: .session(.recovering))
        )
        check.equal("a new engine epoch is adopted", state.engineEpoch, 8)
        check.check("a new engine epoch clears old pending commands", state.pendingCommands.isEmpty)
        check.equal("the new engine begins a fresh revision namespace", state.sourceRevisions[.engineConnection], 1)

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(account: 5, engine: 1, source: .account, revision: 1, event: .session(.connecting))
        )
        check.equal("a new account epoch is adopted", state.accountEpoch, 5)
        check.equal("engine epochs restart within a new account", state.engineEpoch, 1)
        check.equal("the new account event is applied", state.session, .connecting)
        check.equal("a new account cannot inherit playback ownership", state.owner, .none)
        check.nil_("a new account cannot inherit the prior track", state.currentTrack)
        check.check("a new account cannot inherit pending commands", state.pendingCommands.isEmpty)
    }

    check.suite("Playback reducer source revisions") {
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        let firstAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .enginePlayback, revision: 10, event: .transport(.playing))
        )
        check.check("the first revision is accepted", firstAccepted)
        check.equal("accepted revisions are recorded", state.sourceRevisions[.enginePlayback], 10)

        let afterFirst = state
        let olderAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .enginePlayback, revision: 9, event: .transport(.paused))
        )
        check.check("an older source revision is rejected", !olderAccepted)
        check.equal("an older source revision changes nothing", state, afterFirst)

        let duplicateAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .enginePlayback, revision: 10, event: .transport(.paused))
        )
        check.check("a duplicate source revision is rejected", !duplicateAccepted)
        check.equal("a duplicate source revision changes nothing", state, afterFirst)

        let independentAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .engineQueue, revision: 1, event: .notice(PlaybackNotice(message: "queue observed")))
        )
        check.check("independent sources have independent revisions", independentAccepted)
        check.equal("the playback revision remains intact", state.sourceRevisions[.enginePlayback], 10)
        check.equal("the queue revision is tracked separately", state.sourceRevisions[.engineQueue], 1)

        let beforeInvalidCommandResult = state
        let unknownID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let unknownAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .command, revision: 5, event: .commandFinished(id: unknownID, accepted: true, notice: nil))
        )
        check.check("an acknowledgement for no pending command is rejected", !unknownAccepted)
        check.equal("a rejected acknowledgement is transactionally inert", state, beforeInvalidCommandResult)

        state.devices = PlaybackDeviceSnapshot(
            devices: [PlaybackDevice(id: "new", name: "New", type: "computer")],
            localDeviceID: "new",
            revision: 8
        )
        let beforeStaleDevices = state
        let staleDevicesAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .engineDevices,
                revision: 1,
                event: .devices(PlaybackDeviceSnapshot(
                    devices: [PlaybackDevice(id: "old", name: "Old", type: "computer")],
                    localDeviceID: "old",
                    revision: 7
                ))
            )
        )
        check.check("a stale embedded device revision is rejected", !staleDevicesAccepted)
        check.equal("a stale device event cannot consume its envelope revision", state, beforeStaleDevices)

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .account, revision: 20, event: .reset(session: .signedOut))
        )
        let afterReset = state
        let staleAfterResetAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .account, revision: 19, event: .session(.ready))
        )
        check.check("reset retains its revision barrier", !staleAfterResetAccepted)
        check.equal("a stale pre-reset event cannot revive the session", state, afterReset)
    }

    check.suite("Playback reducer ordering-gate queries") {
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .enginePlayback, revision: 4, event: .transport(.playing))
        )
        let beforeQuery = state

        check.check(
            "a newer playback revision would be accepted",
            PlaybackReducer.accepts(
                state,
                accountEpoch: 1,
                engineEpoch: 1,
                source: .enginePlayback,
                revision: 5
            )
        )
        check.equal("an acceptance query does not record the revision", state, beforeQuery)

        check.check(
            "a duplicate playback revision would be rejected",
            !PlaybackReducer.accepts(
                state,
                accountEpoch: 1,
                engineEpoch: 1,
                source: .enginePlayback,
                revision: 4
            )
        )
        check.equal("a rejection query is also inert", state, beforeQuery)

        check.check(
            "a higher engine epoch opens a fresh revision namespace for the query",
            PlaybackReducer.accepts(
                state,
                accountEpoch: 1,
                engineEpoch: 2,
                source: .enginePlayback,
                revision: 1
            )
        )
        check.equal("a higher-epoch query does not adopt the epoch", state.engineEpoch, 1)
        check.equal("a higher-epoch query does not clear recorded revisions", state.sourceRevisions[.enginePlayback], 4)
    }

    check.suite("Playback reducer device revisions across engine epochs") {
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        state.devices = PlaybackDeviceSnapshot(
            devices: [PlaybackDevice(id: "old", name: "Old", type: "computer")],
            localDeviceID: "old",
            revision: 8
        )

        let restartedDevicesAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                engine: 2,
                source: .engineDevices,
                revision: 1,
                event: .devices(PlaybackDeviceSnapshot(
                    devices: [PlaybackDevice(id: "restarted", name: "Restarted", type: "computer")],
                    localDeviceID: "restarted",
                    revision: 1
                ))
            )
        )
        check.check("a new engine epoch accepts a restarted device revision", restartedDevicesAccepted)
        check.equal("the restarted engine epoch is adopted", state.engineEpoch, 2)
        check.equal("the new engine's device snapshot replaces the prior revision", state.devices.revision, 1)
        check.equal("the new engine's active device is adopted", state.devices.localDeviceID, "restarted")
    }

    check.suite("Optimistic playback command reconciliation") {
        let pauseID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready, transport: .playing)

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(id: pauseID, kind: .transport, expectedTransport: .paused, startedAt: traceDate))
            )
        )
        check.equal("a pending pause updates the presentation immediately", state.transport, .paused)
        check.equal("the pause command is tracked by kind", state.pendingCommands[.transport]?.id, pauseID)

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .enginePlayback, revision: 1, event: .transport(.playing))
        )
        check.equal("a contradictory stale snapshot cannot undo the optimistic pause", state.transport, .paused)
        check.equal("the stale contradiction does not clear the pending command", state.pendingCommands[.transport]?.id, pauseID)

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .enginePlayback, revision: 2, event: .transport(.paused))
        )
        check.equal("a matching authoritative snapshot keeps the expected state", state.transport, .paused)
        check.nil_("a matching authoritative snapshot reconciles the command", state.pendingCommands[.transport])

        let afterReconcile = state
        let lateFinishAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .command, event: .commandFinished(id: pauseID, accepted: true, notice: nil))
        )
        check.check("a late finish after snapshot reconciliation is rejected", !lateFinishAccepted)
        check.equal("a late finish cannot mutate already-reconciled state", state, afterReconcile)

        let resumeID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(id: resumeID, kind: .transport, expectedTransport: .playing, startedAt: traceDate))
            )
        )
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .command, event: .commandFinished(id: resumeID, accepted: true, notice: nil))
        )
        check.nil_("an accepted acknowledgement clears its exact command", state.pendingCommands[.transport])
        check.equal("an accepted acknowledgement keeps the optimistic result", state.transport, .playing)

        let supersededID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let replacementID = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(id: supersededID, kind: .transport, expectedTransport: .paused, startedAt: traceDate))
            )
        )
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(id: replacementID, kind: .transport, expectedTransport: .playing, startedAt: traceDate.addingTimeInterval(1)))
            )
        )
        let afterReplacement = state
        let supersededAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .command, event: .commandFinished(id: supersededID, accepted: true, notice: nil))
        )
        check.check("an acknowledgement for a superseded command is rejected", !supersededAccepted)
        check.equal("a superseded acknowledgement cannot clear the replacement", state, afterReplacement)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .command, event: .commandFinished(id: replacementID, accepted: true, notice: nil))
        )
        check.nil_("the replacement command reconciles by its own identity", state.pendingCommands[.transport])

        let rejectedID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(id: rejectedID, kind: .transport, expectedTransport: .paused, startedAt: traceDate))
            )
        )
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .command, event: .commandFinished(id: rejectedID, accepted: false, notice: PlaybackNotice(message: "Pause failed")))
        )
        check.nil_("a rejected acknowledgement clears its command", state.pendingCommands[.transport])
        check.equal("a rejected acknowledgement rolls back its optimistic transport", state.transport, .playing)
        check.equal("a rejected acknowledgement surfaces its notice", state.notice?.message, "Pause failed")

        let recoveryID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandStarted(PendingPlaybackCommand(
                    id: recoveryID,
                    kind: .transport,
                    expectedTransport: .paused,
                    startedAt: traceDate
                ))
            )
        )
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .command, event: .commandFinished(id: recoveryID, accepted: true, notice: nil))
        )
        check.equal(
            "an accepted acknowledgement does not clear an unrelated prior notice",
            state.notice?.message,
            "Pause failed"
        )
        check.equal("an accepted acknowledgement keeps its optimistic transport", state.transport, .paused)
    }

    check.suite("Remote paused playback ownership") {
        let remote = PlaybackDevice(id: "desktop", name: "Other Mac", type: "computer")
        let track = CurrentTrack(uri: "spotify:track:paused", title: "Paused Track", artist: "Artist", duration: 240, metadataSource: .connect)
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        let trace = TraceHarness(initialState: state) { state, event in
            _ = PlaybackReducer.reduce(&state, envelope: event)
        }
        let states = trace.replay([
            envelope(source: .engineDevices, revision: 1, event: .owner(.remote(remote))),
            envelope(source: .enginePlayback, revision: 1, event: .currentTrack(track)),
            envelope(source: .enginePlayback, revision: 2, event: .transport(.paused)),
        ])
        state = states.last ?? state
        check.equal("paused playback retains the remote owner", state.owner, .remote(remote))
        check.equal("remote pause is represented as paused, not stopped", state.transport, .paused)
        check.equal("remote pause retains now-playing metadata", state.currentTrack, track)
    }

    check.suite("Atomic engine snapshots") {
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .connecting)
        let remote = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .engineConnection,
                revision: 10,
                event: .engineConnection(EngineConnectionSnapshot(
                    session: .ready,
                    owner: .remote(remote),
                    localDeviceID: "aural"
                ))
            )
        )
        check.equal("connection snapshot changes session and owner together", state.session, .ready)
        check.equal("connection snapshot owns the remote device", state.owner, .remote(remote))
        check.equal("connection snapshot carries the local route identity", state.devices.localDeviceID, "aural")

        let timing = PlaybackTiming(position: 42, duration: 180, anchoredAt: traceDate)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .enginePlayback,
                revision: 20,
                event: .enginePlayback(EnginePlaybackSnapshot(
                    transport: .paused,
                    trackURI: "spotify:track:atomic",
                    timing: timing,
                    shuffle: true,
                    repeatMode: .context
                ))
            )
        )
        check.equal("one playback event installs track identity", state.currentTrack?.uri, "spotify:track:atomic")
        check.equal("one playback event installs transport", state.transport, .paused)
        check.equal("one playback event installs timing", state.timing, timing)
        check.equal("one playback event installs shuffle", state.options.shuffle, true)
        check.equal("one playback event installs repeat", state.options.repeatMode, .context)

        let afterFresh = state
        let staleAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .enginePlayback,
                revision: 19,
                event: .enginePlayback(EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: "spotify:track:stale",
                    timing: PlaybackTiming(position: 0, duration: 1, anchoredAt: traceDate),
                    shuffle: false,
                    repeatMode: .off
                ))
            )
        )
        check.check("a stale atomic snapshot is rejected as one unit", !staleAccepted)
        check.equal("a stale atomic snapshot cannot partially mutate state", state, afterFresh)

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .engineDevices,
                revision: 30,
                event: .devices(PlaybackDeviceSnapshot(
                    devices: [PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")],
                    localDeviceID: "aural",
                    revision: 30
                ))
            )
        )
        check.equal(
            "an inactive paused device becomes an explicit uncertain candidate",
            state.owner,
            .uncertain(PlaybackDevice(id: "phone", name: "Phone", type: "smartphone"))
        )
    }

    check.suite("Atomic playback presentation and metadata") {
        let oldTrack = CurrentTrack(
            uri: "spotify:track:old",
            title: "Old title",
            artist: "Old artist",
            duration: 100,
            metadataSource: .catalog
        )
        var state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing,
            currentTrack: oldTrack,
            timing: PlaybackTiming(position: 90, duration: 100, anchoredAt: traceDate)
        )
        let newTrack = CurrentTrack(
            uri: "spotify:track:new",
            title: "New title",
            artist: "New artist",
            duration: 240,
            metadataSource: .catalog
        )
        let newTiming = PlaybackTiming(position: 0, duration: 240, anchoredAt: traceDate)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .user,
                event: .presentation(PlaybackPresentationSnapshot(
                    currentTrack: newTrack,
                    transport: .paused,
                    timing: newTiming
                ))
            )
        )
        check.equal("one presentation event installs the complete track", state.currentTrack, newTrack)
        check.equal("one presentation event installs transport", state.transport, .paused)
        check.equal("one presentation event installs timing", state.timing, newTiming)

        let beforeStaleMetadata = state
        let staleAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .metadata,
                event: .trackMetadata(PlaybackTrackMetadata(
                    uri: oldTrack.uri,
                    title: "Stale",
                    artist: "Stale",
                    artworkURL: nil,
                    duration: 1,
                    source: .connect
                ))
            )
        )
        check.check("metadata for a previous track is rejected", !staleAccepted)
        check.equal("rejected metadata is transactionally inert", state, beforeStaleMetadata)

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .metadata,
                event: .trackMetadata(PlaybackTrackMetadata(
                    uri: newTrack.uri,
                    title: "Resolved",
                    artist: "Resolved artist",
                    artworkURL: URL(string: "https://example.com/art.jpg"),
                    duration: 245,
                    source: .connect
                ))
            )
        )
        check.equal("metadata fields arrive as one coherent value", state.currentTrack?.title, "Resolved")
        check.equal("metadata provenance is retained", state.currentTrack?.metadataSource, .connect)
        check.equal("metadata duration updates playback timing atomically", state.timing.duration, 245)

        let beforeStaleMetadataAccount = state
        let staleMetadataAccount = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                account: 0,
                source: .metadata,
                event: .trackMetadata(PlaybackTrackMetadata(
                    uri: newTrack.uri,
                    title: "Late",
                    artist: "Late",
                    artworkURL: nil,
                    duration: 1,
                    source: .connect
                ))
            )
        )
        check.check("metadata from a previous account is rejected", !staleMetadataAccount)
        check.equal("stale-account metadata is inert", state, beforeStaleMetadataAccount)

        let beforeStaleMetadataEngine = state
        let staleMetadataEngine = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                engine: 0,
                source: .metadata,
                event: .trackMetadata(PlaybackTrackMetadata(
                    uri: newTrack.uri,
                    title: "Late engine",
                    artist: "Late engine",
                    artworkURL: nil,
                    duration: 1,
                    source: .connect
                ))
            )
        )
        check.check("metadata from a previous engine is rejected", !staleMetadataEngine)
        check.equal("stale-engine metadata is inert", state, beforeStaleMetadataEngine)
    }

    check.suite("Timing outcomes use reducer identity") {
        var state = PlaybackState(
            accountEpoch: 2,
            engineEpoch: 3,
            session: .ready,
            transport: .playing,
            currentTrack: CurrentTrack(uri: "spotify:track:now", title: "Now", metadataSource: .catalog),
            timing: PlaybackTiming(position: 10, duration: 200, anchoredAt: traceDate)
        )

        let accepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                account: 2,
                engine: 3,
                source: .user,
                event: .timing(position: 42, duration: 200, anchoredAt: traceDate)
            )
        )
        check.check("a same-lifetime position refresh is accepted", accepted)
        check.equal("accepted timing replaces the anchored position", state.timing.position, 42)

        let beforeStaleAccount = state
        let staleAccount = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                account: 1,
                engine: 3,
                source: .user,
                event: .timing(position: 99, duration: 200, anchoredAt: traceDate)
            )
        )
        check.check("a stale-account position refresh is rejected", !staleAccount)
        check.equal("a stale-account position refresh is inert", state, beforeStaleAccount)

        let beforeStaleEngine = state
        let staleEngine = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                account: 2,
                engine: 2,
                source: .user,
                event: .timing(position: 99, duration: 200, anchoredAt: traceDate)
            )
        )
        check.check("a stale-engine position refresh is rejected", !staleEngine)
        check.equal("a stale-engine position refresh is inert", state, beforeStaleEngine)
    }

    check.suite("Queue precedence and identity") {
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        let provisionalEmpty = queue([], source: .provisional, completeness: .partial, revision: 100)
        let exact = queue([item("a"), item("b")], source: .webAPI, completeness: .complete, revision: 1)

        _ = PlaybackReducer.reduce(&state, envelope: envelope(source: .engineQueue, revision: 1, event: .queue(provisionalEmpty)))
        check.check("a first provisional empty queue can characterize absence", state.queue.entries.isEmpty)
        check.equal("the provisional source remains explicit", state.queue.source, .provisional)

        _ = PlaybackReducer.reduce(&state, envelope: envelope(source: .engineQueue, revision: 2, event: .queue(exact)))
        check.equal("an exact queue outranks a higher-revision provisional queue", state.queue, exact)

        let laterProvisionalEmpty = queue([], source: .provisional, completeness: .complete, revision: 999)
        _ = PlaybackReducer.reduce(&state, envelope: envelope(source: .engineQueue, revision: 3, event: .queue(laterProvisionalEmpty)))
        check.equal("a later provisional empty cannot erase an exact queue", state.queue, exact)

        let connectQueue = queue([item("connect", provider: "queue")], source: .connect, completeness: .complete, revision: 999)
        _ = PlaybackReducer.reduce(&state, envelope: envelope(source: .engineQueue, revision: 4, event: .queue(connectQueue)))
        check.equal("a Connect fallback cannot replace the documented queue", state.queue, exact)

        let exactNewer = queue([item("c")], source: .webAPI, completeness: .complete, revision: 2)
        _ = PlaybackReducer.reduce(&state, envelope: envelope(source: .engineQueue, revision: 5, event: .queue(exactNewer)))
        check.equal("a newer exact queue replaces an older exact queue", state.queue, exactNewer)

        let exactStale = queue([item("stale")], source: .webAPI, completeness: .complete, revision: 1)
        _ = PlaybackReducer.reduce(&state, envelope: envelope(source: .engineQueue, revision: 6, event: .queue(exactStale)))
        check.equal("an older queue-source revision is ignored", state.queue, exactNewer)

        let lowerCompleteness = queue([], source: .webAPI, completeness: .metadataOnly, revision: 2)
        _ = PlaybackReducer.reduce(&state, envelope: envelope(source: .engineQueue, revision: 7, event: .queue(lowerCompleteness)))
        check.equal("equal-revision metadata cannot downgrade an exact URI queue", state.queue, exactNewer)

        let duplicates = queue(
            [item("same", occurrence: 0), item("same", occurrence: 1), item("tail")],
            source: .webAPI,
            completeness: .complete,
            revision: 3
        )
        _ = PlaybackReducer.reduce(&state, envelope: envelope(source: .engineQueue, revision: 8, event: .queue(duplicates)))
        check.equal("duplicate queue uris preserve source order", state.queue.entries.map(\.uri), ["spotify:track:same", "spotify:track:same", "spotify:track:tail"])
        check.notEqual("duplicate queue occurrences retain distinct identities", state.queue.entries[0].id, state.queue.entries[1].id)

        var newContext = queue(
            [item("new-context", provider: "queue")],
            source: .connect,
            completeness: .complete,
            revision: 1,
            contextURI: "spotify:track:new"
        )
        newContext.receivedAt = traceDate.addingTimeInterval(100)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .engineQueue, revision: 9, event: .queue(newContext))
        )
        check.equal("a new playback context resets old Web queue precedence", state.queue, newContext)

        var olderOtherContext = queue(
            [item("late-old")],
            source: .webAPI,
            completeness: .complete,
            revision: 99,
            contextURI: "spotify:track:old"
        )
        olderOtherContext.receivedAt = newContext.receivedAt.addingTimeInterval(-1)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .engineQueue, revision: 10, event: .queue(olderOtherContext))
        )
        check.equal("an older queue from another context cannot return late", state.queue, newContext)

        let beforeStaleAccountQueue = state
        let staleAccountQueue = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                account: 0,
                source: .engineQueue,
                revision: 11,
                event: .queue(queue([item("stale-account")], source: .webAPI, completeness: .complete, revision: 100))
            )
        )
        check.check("a stale-account queue snapshot is rejected", !staleAccountQueue)
        check.equal("a stale-account queue snapshot is inert", state, beforeStaleAccountQueue)

        let beforeStaleEngineQueue = state
        let staleEngineQueue = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                engine: 0,
                source: .engineQueue,
                revision: 11,
                event: .queue(queue([item("stale-engine")], source: .webAPI, completeness: .complete, revision: 100))
            )
        )
        check.check("a stale-engine queue snapshot is rejected", !staleEngineQueue)
        check.equal("a stale-engine queue snapshot is inert", state, beforeStaleEngineQueue)
    }

    check.suite("Playback reset invariants") {
        let command = PendingPlaybackCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            kind: .transport,
            expectedTransport: .paused,
            startedAt: traceDate
        )
        var state = PlaybackState(
            accountEpoch: 2,
            engineEpoch: 3,
            session: .ready,
            owner: .remote(PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")),
            transport: .playing,
            currentTrack: CurrentTrack(uri: "spotify:track:old"),
            timing: PlaybackTiming(position: 80, duration: 200, anchoredAt: traceDate),
            options: PlaybackOptions(shuffle: true, repeatMode: .track),
            queue: queue([item("old")], source: .webAPI, completeness: .complete, revision: 9),
            devices: PlaybackDeviceSnapshot(devices: [PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")], localDeviceID: "local", revision: 4),
            pendingCommands: [.transport: command],
            notice: PlaybackNotice(message: "Old notice"),
            sourceRevisions: [.enginePlayback: 50]
        )
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(account: 2, engine: 3, source: .account, revision: 2, event: .reset(session: .signedOut))
        )
        check.equal("reset keeps the current account epoch", state.accountEpoch, 2)
        check.equal("reset keeps the current engine epoch", state.engineEpoch, 3)
        check.equal("reset installs the requested session phase", state.session, .signedOut)
        check.equal("reset clears ownership", state.owner, .none)
        check.equal("reset stops transport", state.transport, .stopped)
        check.nil_("reset clears the current track", state.currentTrack)
        check.equal("reset clears timing", state.timing.position, 0)
        check.check("reset clears the queue", state.queue.entries.isEmpty)
        check.check("reset clears devices", state.devices.devices.isEmpty)
        check.check("reset clears every pending command", state.pendingCommands.isEmpty)
        check.nil_("reset clears notices", state.notice)
        check.equal("reset retains only its own revision barrier", state.sourceRevisions, [.account: 2])
    }
}
