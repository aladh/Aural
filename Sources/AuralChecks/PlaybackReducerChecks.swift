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

private func item(
    _ suffix: String,
    occurrence: Int = 0,
    provider: String = "web-api",
    uid: String = ""
) -> PlaybackQueueItem {
    let uri = "spotify:track:\(suffix)"
    return PlaybackQueueItem(uri: uri, provider: provider, occurrence: occurrence, uid: uid)
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

private let localComputer = PlaybackDevice(id: "local", name: "Aural", type: "computer")
private let inactivePhone = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")
private let activePhone = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
private let activeLocal = PlaybackDevice(id: "local", name: "Aural", type: "computer", isActive: true)

@discardableResult
private func reduceDevices(
    _ state: inout PlaybackState,
    devices: [PlaybackDevice],
    localDeviceID: String? = "local",
    lastRemoteDeviceID: String? = nil,
    revision: UInt64,
    engine: UInt64 = 1,
    account: UInt64 = 1
) -> Bool {
    PlaybackReducer.reduce(
        &state,
        envelope: envelope(
            account: account,
            engine: engine,
            source: .engineDevices,
            revision: revision,
            event: .devices(
                PlaybackDeviceSnapshot(
                    devices: devices,
                    localDeviceID: localDeviceID,
                    revision: revision,
                    lastRemoteDeviceID: lastRemoteDeviceID
                ))
        )
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
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: pendingID, kind: .transport, expectedTransport: .playing, startedAt: traceDate))
            )
        )
        check.notNil("the characterization starts with a pending command", state.pendingCommands[.transport])

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                account: 4, engine: 8, source: .engineConnection, revision: 1, event: .session(.recovering))
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
            envelope: envelope(
                source: .engineQueue, revision: 1, event: .notice(PlaybackNotice(message: "queue observed")))
        )
        check.check("independent sources have independent revisions", independentAccepted)
        check.equal("the playback revision remains intact", state.sourceRevisions[.enginePlayback], 10)
        check.equal("the queue revision is tracked separately", state.sourceRevisions[.engineQueue], 1)

        let beforeInvalidCommandResult = state
        let unknownID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let unknownAccepted = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command, revision: 5, event: .commandFinished(id: unknownID, accepted: true, notice: nil))
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
                event: .devices(
                    PlaybackDeviceSnapshot(
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
                event: .devices(
                    PlaybackDeviceSnapshot(
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
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: pauseID, kind: .transport, expectedTransport: .paused, startedAt: traceDate))
            )
        )
        check.equal("a pending pause updates the presentation immediately", state.transport, .paused)
        check.equal("the pause command is tracked by kind", state.pendingCommands[.transport]?.id, pauseID)

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(source: .enginePlayback, revision: 1, event: .transport(.playing))
        )
        check.equal("a contradictory stale snapshot cannot undo the optimistic pause", state.transport, .paused)
        check.equal(
            "the stale contradiction does not clear the pending command", state.pendingCommands[.transport]?.id, pauseID
        )

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
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: resumeID, kind: .transport, expectedTransport: .playing, startedAt: traceDate))
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
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: supersededID, kind: .transport, expectedTransport: .paused, startedAt: traceDate))
            )
        )
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: replacementID, kind: .transport, expectedTransport: .playing,
                        startedAt: traceDate.addingTimeInterval(1)))
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
            envelope: envelope(
                source: .command, event: .commandFinished(id: replacementID, accepted: true, notice: nil))
        )
        check.nil_("the replacement command reconciles by its own identity", state.pendingCommands[.transport])

        let rejectedID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: rejectedID, kind: .transport, expectedTransport: .paused, startedAt: traceDate))
            )
        )
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandFinished(
                    id: rejectedID, accepted: false, notice: PlaybackNotice(message: "Pause failed")))
        )
        check.nil_("a rejected acknowledgement clears its command", state.pendingCommands[.transport])
        check.equal("a rejected acknowledgement rolls back its optimistic transport", state.transport, .playing)
        check.equal("a rejected acknowledgement surfaces its notice", state.notice?.message, "Pause failed")

        let recoveryID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
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

    check.suite("Options command finish does not clobber engine repeat") {
        let optionsID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        var state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            options: PlaybackOptions(repeatMode: .context)
        )
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: optionsID,
                        kind: .options,
                        expectedTransport: nil,
                        startedAt: traceDate
                    ))
            )
        )
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .enginePlayback,
                revision: 7,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .paused,
                        trackURI: nil,
                        timing: PlaybackTiming(anchoredAt: traceDate),
                        shuffle: false,
                        repeatMode: .track
                    ))
            )
        )
        check.equal(
            "an engine snapshot can update repeat while a shuffle-less options command is pending",
            state.options.repeatMode, .track)
        check.equal(
            "an engine snapshot does not confirm a shuffle-less options command", state.pendingCommands[.options]?.id,
            optionsID)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .command,
                event: .commandFinished(
                    id: optionsID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update repeat")
                )
            )
        )
        check.nil_("a rejected options acknowledgement clears its command", state.pendingCommands[.options])
        check.equal(
            "a rejected options acknowledgement without expected repeat does not roll back repeat",
            state.options.repeatMode,
            .track
        )
        check.equal(
            "a rejected options acknowledgement still surfaces its notice",
            state.notice?.message,
            "Could not update repeat"
        )
        check.equal(
            "engine playback revision is recorded for identity-safe rollback", state.sourceRevisions[.enginePlayback], 7
        )
        check.equal(
            "an engine snapshot without raw flags uses the display mode flags", state.options.repeatFlags,
            RepeatMode.track.flags)

        let bothTrueID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        var flagged = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        _ = PlaybackReducer.reduce(
            &flagged,
            envelope: envelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .paused,
                        trackURI: nil,
                        timing: PlaybackTiming(anchoredAt: traceDate),
                        shuffle: false,
                        repeatMode: .track,
                        repeatFlags: RepeatFlags(context: true, track: true)
                    ))
            )
        )
        check.equal("a both-true snapshot still displays as track", flagged.options.repeatMode, .track)
        check.equal(
            "a both-true snapshot retains the raw context bit",
            flagged.options.repeatFlags,
            RepeatFlags(context: true, track: true)
        )
        _ = PlaybackReducer.reduce(
            &flagged,
            envelope: envelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: bothTrueID,
                        kind: .options,
                        expectedTransport: nil,
                        expectedRepeatFlags: RepeatMode.off.flags,
                        startedAt: traceDate
                    ))
            )
        )
        check.equal(
            "repeat start captures both-true raw flags", flagged.pendingCommands[.options]?.rollbackRepeatFlags,
            RepeatFlags(context: true, track: true))
        check.equal("repeat start applies canonical off flags", flagged.options.repeatFlags, RepeatMode.off.flags)
        check.equal("repeat start displays off", flagged.options.repeatMode, RepeatMode.off)
        _ = PlaybackReducer.reduce(
            &flagged,
            envelope: envelope(
                source: .command,
                event: .commandFinished(
                    id: bothTrueID, accepted: false, notice: PlaybackNotice(message: "Could not update repeat"))
            )
        )
        check.equal(
            "a rejected repeat finish restores captured both-true flags",
            flagged.options.repeatFlags,
            RepeatFlags(context: true, track: true)
        )
        check.equal("a rejected repeat finish restores track display", flagged.options.repeatMode, .track)

        var restored = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        let priorBothTrue = RepeatFlags(context: true, track: true)
        let intermediateFlags = RepeatFlags(context: false, track: true)
        let restoreID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
        _ = PlaybackReducer.reduce(
            &restored,
            envelope: envelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .paused,
                        trackURI: nil,
                        timing: PlaybackTiming(anchoredAt: traceDate),
                        shuffle: false,
                        repeatMode: .track,
                        repeatFlags: priorBothTrue
                    ))
            )
        )
        _ = PlaybackReducer.reduce(
            &restored,
            envelope: envelope(
                source: .command,
                event: .commandStarted(
                    PendingPlaybackCommand(
                        id: restoreID,
                        kind: .options,
                        expectedTransport: nil,
                        expectedRepeatFlags: RepeatMode.off.flags,
                        startedAt: traceDate
                    ))
            )
        )
        check.equal("optimistic both-true track → off displays off", restored.options.repeatMode, .off)
        _ = PlaybackReducer.reduce(
            &restored,
            envelope: envelope(
                source: .enginePlayback,
                revision: 2,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .paused,
                        trackURI: nil,
                        timing: PlaybackTiming(anchoredAt: traceDate),
                        shuffle: false,
                        repeatMode: .track,
                        repeatFlags: intermediateFlags
                    ))
            )
        )
        check.equal("intermediate (false, true) still displays as track", restored.options.repeatMode, .track)
        check.equal(
            "intermediate snapshot replaces optimistic off flags",
            restored.options.repeatFlags,
            intermediateFlags
        )
        check.equal("an intermediate snapshot does not confirm off", restored.pendingCommands[.options]?.id, restoreID)
        check.nil_(
            "an intermediate snapshot is not confirmation or supersession",
            restored.transportCommandResolutions[restoreID])
        _ = PlaybackReducer.reduce(
            &restored,
            envelope: envelope(
                source: .command,
                event: .commandFinished(
                    id: restoreID,
                    accepted: false,
                    notice: PlaybackNotice(message: "Could not update repeat")
                )
            )
        )
        check.equal("restored repeat mode is track", restored.options.repeatMode, .track)
        check.equal(
            "restored raw flags are the captured both-true pair",
            restored.options.repeatFlags,
            priorBothTrue
        )
        check.equal(
            "a later track → off from restored flags plans both mutations",
            RepeatTransitionPlan.planning(from: restored.options.repeatFlags, to: RepeatMode.off.flags).mutations,
            [
                RepeatFlagMutation(flag: .context, enabled: false),
                RepeatFlagMutation(flag: .track, enabled: false),
            ]
        )
        check.equal(
            "ordinary (false, true) track → off remains one mutation",
            RepeatTransitionPlan.planning(from: intermediateFlags, to: RepeatMode.off.flags).mutations,
            [RepeatFlagMutation(flag: .track, enabled: false)]
        )
    }

    check.suite("Remote paused playback ownership") {
        let remote = PlaybackDevice(id: "desktop", name: "Other Mac", type: "computer")
        let track = CurrentTrack(
            uri: "spotify:track:paused", title: "Paused Track", artist: "Artist", duration: 240,
            metadataSource: .connect)
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

    check.suite("Playback reducer device owner resolution") {
        let pausedURI = "spotify:track:paused-remote"
        let cluster = [localComputer, inactivePhone]

        var launch = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        _ = reduceDevices(&launch, devices: cluster, lastRemoteDeviceID: "phone", revision: 1)
        check.equal("devices-first with no track is none", launch.owner, .none)
        check.equal(
            "the last-remote payload is stamped for later URI adoption", launch.devices.lastRemoteDeviceID, "phone")
        _ = PlaybackReducer.reduce(
            &launch,
            envelope: envelope(
                source: .enginePlayback,
                revision: 1,
                event: .currentTrack(CurrentTrack(uri: pausedURI))
            )
        )
        check.equal(
            "a later URI adopts the stamped last-remote candidate",
            launch.owner,
            .uncertain(inactivePhone)
        )
        check.equal(
            "devices-then-track stays remote-routable",
            connectCommandRoute(owner: launch.owner, localDeviceID: "local"),
            .remote(from: "local", to: "phone")
        )
        _ = PlaybackReducer.reduce(
            &launch,
            envelope: envelope(source: .enginePlayback, revision: 2, event: .currentTrack(nil))
        )
        check.equal("clearing the URI drops an uncertain last-remote owner", launch.owner, .none)

        var missing = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        _ = reduceDevices(&missing, devices: cluster, lastRemoteDeviceID: "missing-speaker", revision: 1)
        _ = PlaybackReducer.reduce(
            &missing,
            envelope: envelope(
                source: .enginePlayback,
                revision: 1,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .paused,
                        trackURI: pausedURI,
                        timing: PlaybackTiming(position: 0, duration: 180, anchoredAt: traceDate)
                    ))
            )
        )
        check.equal("a stale last-remote after devices-then-track is uncertain(nil)", missing.owner, .uncertain(nil))
        check.equal(
            "a stale last-remote never becomes local",
            connectCommandRoute(owner: missing.owner, localDeviceID: "local"),
            .waitingForLocalIdentity
        )

        var withTrack = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            currentTrack: CurrentTrack(uri: pausedURI)
        )
        _ = reduceDevices(&withTrack, devices: cluster, lastRemoteDeviceID: "phone", revision: 1)
        check.equal(
            "a no-active snapshot that already has a track uses last-remote",
            withTrack.owner,
            .uncertain(inactivePhone)
        )

        var namedPrevious = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            owner: .remote(PlaybackDevice(id: "phone", name: "Old Phone", type: "smartphone")),
            currentTrack: CurrentTrack(uri: pausedURI)
        )
        _ = reduceDevices(&namedPrevious, devices: cluster, revision: 1)
        check.equal(
            "a previous remote candidate refreshes from the device list",
            namedPrevious.owner,
            .uncertain(inactivePhone)
        )

        var noTrack = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready, owner: .remote(inactivePhone))
        _ = reduceDevices(&noTrack, devices: cluster, lastRemoteDeviceID: "phone", revision: 1)
        check.equal("no current track clears ownership even with a last remote", noTrack.owner, .none)

        var activeLocalState = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            currentTrack: CurrentTrack(uri: pausedURI)
        )
        _ = reduceDevices(
            &activeLocalState,
            devices: [activeLocal, inactivePhone],
            lastRemoteDeviceID: "phone",
            revision: 1
        )
        check.equal(
            "an active local device wins over last-remote fallback", activeLocalState.owner, .local(activeLocal))

        var activeRemoteState = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        _ = reduceDevices(
            &activeRemoteState,
            devices: [localComputer, activePhone],
            lastRemoteDeviceID: "phone",
            revision: 1
        )
        check.equal("an active remote device is remote ownership", activeRemoteState.owner, .remote(activePhone))

        let connectionRemote = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
        var connected = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        _ = reduceDevices(&connected, devices: cluster, lastRemoteDeviceID: "phone", revision: 1)
        _ = PlaybackReducer.reduce(
            &connected,
            envelope: envelope(
                source: .engineConnection,
                revision: 1,
                event: .engineConnection(
                    EngineConnectionSnapshot(
                        session: .ready,
                        owner: .remote(connectionRemote),
                        localDeviceID: "local"
                    ))
            )
        )
        _ = PlaybackReducer.reduce(
            &connected,
            envelope: envelope(
                source: .enginePlayback,
                revision: 1,
                event: .currentTrack(CurrentTrack(uri: pausedURI))
            )
        )
        check.equal(
            "a later URI does not weaken an identified remote owner from connection",
            connected.owner,
            .remote(connectionRemote)
        )

        var gated = PlaybackState(
            accountEpoch: 4,
            engineEpoch: 7,
            session: .ready,
            owner: .none,
            currentTrack: CurrentTrack(uri: pausedURI),
            devices: PlaybackDeviceSnapshot(devices: cluster, localDeviceID: "local", revision: 3)
        )
        _ = reduceDevices(
            &gated,
            devices: cluster,
            lastRemoteDeviceID: "phone",
            revision: 4,
            engine: 7,
            account: 4
        )
        let afterAccepted = gated
        check.check(
            "a stale device revision is rejected",
            !reduceDevices(
                &gated,
                devices: [localComputer, activePhone],
                lastRemoteDeviceID: "phone",
                revision: 3,
                engine: 7,
                account: 4
            )
        )
        check.equal("a stale device revision is inert", gated, afterAccepted)
        check.check(
            "a stale engine epoch is rejected",
            !reduceDevices(
                &gated,
                devices: [localComputer, activePhone],
                lastRemoteDeviceID: "phone",
                revision: 5,
                engine: 6,
                account: 4
            )
        )
        check.equal("a stale engine epoch is inert", gated, afterAccepted)
        check.check(
            "a stale account epoch is rejected",
            !reduceDevices(
                &gated,
                devices: [localComputer, activePhone],
                lastRemoteDeviceID: "phone",
                revision: 5,
                engine: 7,
                account: 3
            )
        )
        check.equal("a stale account epoch is inert", gated, afterAccepted)
    }

    check.suite("Atomic engine snapshots") {
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .connecting)
        let remote = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                source: .engineConnection,
                revision: 10,
                event: .engineConnection(
                    EngineConnectionSnapshot(
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
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
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
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
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
                event: .devices(
                    PlaybackDeviceSnapshot(
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
                event: .presentation(
                    PlaybackPresentationSnapshot(
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
                event: .trackMetadata(
                    PlaybackTrackMetadata(
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
                event: .trackMetadata(
                    PlaybackTrackMetadata(
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
                event: .trackMetadata(
                    PlaybackTrackMetadata(
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
                event: .trackMetadata(
                    PlaybackTrackMetadata(
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

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(account: 2, engine: 3, source: .user, event: .transport(.paused))
        )
        check.equal("pause transport keeps the existing timing anchor", state.timing.anchoredAt, traceDate)

        let seekAt = traceDate.addingTimeInterval(30)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                account: 2,
                engine: 3,
                source: .user,
                event: .timing(position: 80, duration: 200, anchoredAt: seekAt)
            )
        )
        check.equal("seek replaces the pause anchor", state.timing.anchoredAt, seekAt)

        _ = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                account: 2,
                engine: 3,
                source: .enginePlayback,
                revision: 7,
                event: .enginePlayback(
                    EnginePlaybackSnapshot(
                        transport: .playing,
                        trackURI: "spotify:track:now",
                        timing: PlaybackTiming(position: 81, duration: 200, anchoredAt: seekAt.addingTimeInterval(1))
                    ))
            )
        )
        check.equal(
            "engine timing uses the snapshot anchor, not the source revision",
            state.timing.anchoredAt,
            seekAt.addingTimeInterval(1)
        )
        check.equal(
            "engine playback records the backend revision separately", state.sourceRevisions[.enginePlayback], 7)
    }

    check.suite("Queue precedence and identity") {
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        let provisionalEmpty = queue([], source: .provisional, completeness: .partial, revision: 100)
        let exact = queue([item("a"), item("b")], source: .webAPI, completeness: .complete, revision: 1)

        _ = PlaybackReducer.reduce(
            &state, envelope: envelope(source: .engineQueue, revision: 1, event: .queue(provisionalEmpty)))
        check.check("a first provisional empty queue can characterize absence", state.queue.entries.isEmpty)
        check.equal("the provisional source remains explicit", state.queue.source, .provisional)

        _ = PlaybackReducer.reduce(&state, envelope: envelope(source: .engineQueue, revision: 2, event: .queue(exact)))
        check.equal("an exact queue outranks a higher-revision provisional queue", state.queue, exact)

        let laterProvisionalEmpty = queue([], source: .provisional, completeness: .complete, revision: 999)
        _ = PlaybackReducer.reduce(
            &state, envelope: envelope(source: .engineQueue, revision: 3, event: .queue(laterProvisionalEmpty)))
        check.equal("a later provisional empty cannot erase an exact queue", state.queue, exact)

        let connectQueue = queue(
            [item("connect", occurrence: 4, provider: "queue", uid: "occ-connect")],
            source: .connect,
            completeness: .complete,
            revision: 2
        )
        _ = PlaybackReducer.reduce(
            &state, envelope: envelope(source: .engineQueue, revision: 4, event: .queue(connectQueue)))
        check.equal(
            "a complete Connect snapshot owns occurrence order over Web API",
            state.queue.entries.map(\.uri),
            connectQueue.entries.map(\.uri)
        )
        check.equal("Connect remains the ordering source", state.queue.source, .connect)
        check.equal("Connect keeps its typed occurrence", state.queue.entries.first?.occurrence, 4)
        check.equal("Connect keeps its occurrence uid", state.queue.entries.first?.uid, "occ-connect")

        let webReorder = queue(
            [item("c"), item("a")],
            source: .webAPI,
            completeness: .complete,
            revision: 50
        )
        _ = PlaybackReducer.reduce(
            &state, envelope: envelope(source: .engineQueue, revision: 5, event: .queue(webReorder)))
        check.equal(
            "a same-context Web refresh cannot reorder complete Connect occurrences",
            state.queue.entries.map(\.uri),
            connectQueue.entries.map(\.uri)
        )
        check.equal("Web refresh does not take ownership of Connect order", state.queue.source, .connect)
        check.equal("Web refresh does not replace Connect typed occurrence", state.queue.entries.first?.occurrence, 4)
        check.equal(
            "Web refresh does not replace Connect occurrence uid", state.queue.entries.first?.uid, "occ-connect")
        check.equal(
            "a high-revision Web refresh does not overwrite the Connect ordering revision",
            state.queue.revision,
            connectQueue.revision
        )
        check.equal(
            "a high-revision Web refresh does not overwrite Connect receivedAt",
            state.queue.receivedAt,
            connectQueue.receivedAt
        )

        let exactNewer = queue([item("c")], source: .webAPI, completeness: .complete, revision: 2)
        _ = PlaybackReducer.reduce(
            &state, envelope: envelope(source: .engineQueue, revision: 6, event: .queue(exactNewer)))
        check.equal(
            "a newer Web snapshot still cannot replace complete Connect order",
            state.queue.entries.map(\.uri),
            connectQueue.entries.map(\.uri)
        )

        let exactStale = queue([item("stale")], source: .connect, completeness: .complete, revision: 1)
        _ = PlaybackReducer.reduce(
            &state, envelope: envelope(source: .engineQueue, revision: 7, event: .queue(exactStale)))
        check.equal(
            "an older Connect queue-source revision is ignored", state.queue.entries.map(\.uri),
            connectQueue.entries.map(\.uri))

        let lowerCompleteness = queue([], source: .connect, completeness: .metadataOnly, revision: 2)
        _ = PlaybackReducer.reduce(
            &state, envelope: envelope(source: .engineQueue, revision: 8, event: .queue(lowerCompleteness)))
        check.equal(
            "equal-revision metadata cannot downgrade an exact URI queue", state.queue.entries.map(\.uri),
            connectQueue.entries.map(\.uri))

        let duplicates = queue(
            [
                item("same", occurrence: 0, provider: "queue"), item("same", occurrence: 1, provider: "queue"),
                item("tail", occurrence: 2, provider: "queue"),
            ],
            source: .connect,
            completeness: .complete,
            revision: 3
        )
        _ = PlaybackReducer.reduce(
            &state, envelope: envelope(source: .engineQueue, revision: 9, event: .queue(duplicates)))
        check.equal(
            "duplicate queue uris preserve source order", state.queue.entries.map(\.uri),
            ["spotify:track:same", "spotify:track:same", "spotify:track:tail"])
        check.equal("the later Connect occurrence list keeps its own revision", state.queue.revision, 3)
        check.equal(
            "duplicate queue rows retain typed occurrence order", state.queue.entries.map(\.occurrence), [0, 1, 2])
        let duplicateIDs = state.queue.entries.map(\.id)
        check.check(
            "duplicate queue occurrences retain distinct identities",
            duplicateIDs.count == 3 && Set(duplicateIDs).count == duplicateIDs.count
        )

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
            envelope: envelope(source: .engineQueue, revision: 10, event: .queue(newContext))
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
            envelope: envelope(source: .engineQueue, revision: 11, event: .queue(olderOtherContext))
        )
        check.equal("an older queue from another context cannot return late", state.queue, newContext)

        let beforeStaleAccountQueue = state
        let staleAccountQueue = PlaybackReducer.reduce(
            &state,
            envelope: envelope(
                account: 0,
                source: .engineQueue,
                revision: 12,
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
                revision: 12,
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
            devices: PlaybackDeviceSnapshot(
                devices: [PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")], localDeviceID: "local",
                revision: 4),
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
