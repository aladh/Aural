import AuralDomain
import Foundation

/// Deterministic pause workflow for issue 18. It mirrors `PlaybackStore.send` (which calls
/// `PlaybackReducer.reduce`) and does not ship.

private let spikeDate = Date(timeIntervalSince1970: 1_000_000)
private let pauseNoticeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

private enum CommandWorkResult: Equatable {
    case succeeded
    case remoteFailed
    case reconnectRequired
}

private struct InFlightCommand: Equatable {
    var id: UUID
    var lifetime: PlaybackLifetime
    var cancelled: Bool
}

private final class CommandSession {
    var state: PlaybackState
    var accountEpoch: UInt64
    var engineGeneration: UInt64
    var isTearingDown = false
    var reconnectCount = 0
    var completions: [Bool] = []

    init() {
        accountEpoch = 1
        engineGeneration = 1
        state = PlaybackState(
            accountEpoch: 1,
            engineEpoch: 1,
            session: .ready,
            transport: .playing
        )
    }

    @discardableResult
    func send(
        _ event: PlaybackEvent,
        source: PlaybackEventSource = .command,
        revision: UInt64? = nil,
        engineEpoch: UInt64? = nil,
        accountEpoch: UInt64? = nil
    ) -> Bool {
        let stampedAccountEpoch = accountEpoch ?? self.accountEpoch
        let stampedEngineEpoch = engineEpoch ?? engineGeneration
        var next = state
        let accepted = PlaybackReducer.reduce(
            &next,
            envelope: PlaybackEventEnvelope(
                accountEpoch: stampedAccountEpoch,
                engineEpoch: stampedEngineEpoch,
                source: source,
                revision: revision,
                receivedAt: spikeDate,
                event: event
            )
        )
        if accepted {
            state = next
            engineGeneration = next.engineEpoch
        }
        return accepted
    }

    func applyFinish(commandID: UUID, capturedLifetime: PlaybackLifetime, result: CommandWorkResult) {
        let succeeded = result == .succeeded
        let finished = send(
            .commandFinished(
                id: commandID,
                accepted: succeeded,
                notice: succeeded ? nil : PlaybackNotice(id: pauseNoticeID, message: "Pause was rejected")
            ),
            engineEpoch: capturedLifetime.engineGeneration,
            accountEpoch: capturedLifetime.accountEpoch
        )
        switch playbackCommandFollowUp(
            finishAccepted: finished,
            operationSucceeded: succeeded,
            requiresReconnect: result == .reconnectRequired,
            commandKind: .transport,
            pendingCommandID: state.pendingCommands[.transport]?.id,
            capturedLifetime: capturedLifetime,
            currentLifetime: PlaybackLifetime(
                accountEpoch: accountEpoch,
                engineGeneration: engineGeneration
            ),
            isTearingDown: isTearingDown
        ) {
        case .reportSuccess:
            completions.append(true)
        case let .reportFailure(reconnect):
            completions.append(false)
            if reconnect { reconnectCount += 1 }
        case .inert:
            break
        }
    }

    func restartEngine() {
        _ = send(
            .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
            source: .engineConnection,
            revision: (state.sourceRevisions[.engineConnection] ?? 0) + 1,
            engineEpoch: engineGeneration + 1
        )
    }

    func invalidateAccount() {
        isTearingDown = true
        accountEpoch += 1
        engineGeneration += 1
        _ = send(.reset(session: .signedOut), source: .account, engineEpoch: engineGeneration)
    }
}

/// Registry-shaped owner: unique command tokens, refuse a second pause, cancel-in-flight per token.
private final class RegistryRuntime {
    let session = CommandSession()
    private var inflight: InFlightCommand?

    var transport: PlaybackTransportState { session.state.transport }
    var pending: PendingPlaybackCommand? { session.state.pendingCommands[.transport] }

    @discardableResult
    func requestPause() -> Bool {
        guard
            playbackCommandShouldAdmit(
                isTearingDown: session.isTearingDown,
                allowsCommands: true,
                hasPendingCommandForKind: session.state.pendingCommands[.transport] != nil
            )
        else {
            session.completions.append(false)
            return false
        }
        let commandID = UUID()
        let started = session.send(
            .commandStarted(
                PendingPlaybackCommand(
                    id: commandID,
                    kind: .transport,
                    expectedTransport: .paused,
                    startedAt: spikeDate
                ))
        )
        guard started else {
            session.completions.append(false)
            return false
        }
        inflight = InFlightCommand(
            id: commandID,
            lifetime: PlaybackLifetime(
                accountEpoch: session.accountEpoch,
                engineGeneration: session.engineGeneration
            ),
            cancelled: false
        )
        return true
    }

    func deliver(_ result: CommandWorkResult) {
        guard let command = inflight else { return }
        inflight = nil
        guard !command.cancelled else { return }
        session.applyFinish(
            commandID: command.id,
            capturedLifetime: command.lifetime,
            result: result
        )
    }

    func cancelInFlight() {
        guard let command = inflight else { return }
        inflight?.cancelled = true
        guard
            playbackCommandShouldSettleOrdinaryCancellation(
                pendingCommandID: session.state.pendingCommands[.transport]?.id,
                cancelledCommandID: command.id,
                capturedLifetime: command.lifetime,
                currentLifetime: PlaybackLifetime(
                    accountEpoch: session.accountEpoch,
                    engineGeneration: session.engineGeneration
                ),
                isTearingDown: session.isTearingDown
            )
        else { return }
        let finished = session.send(
            .commandFinished(id: command.id, accepted: false, notice: nil),
            engineEpoch: command.lifetime.engineGeneration,
            accountEpoch: command.lifetime.accountEpoch
        )
        if finished {
            session.completions.append(false)
        }
    }

    func invalidateAccount() {
        inflight?.cancelled = true
        inflight = nil
        session.invalidateAccount()
    }
}

func runPlaybackCommandEffectSpikeChecks(_ check: CheckRunner) {
    check.suite("Registry pause workflow") {
        let success = RegistryRuntime()
        check.check("pause is accepted while idle", success.requestPause())
        check.equal("optimistic pause is visible immediately", success.transport, .paused)
        success.deliver(.succeeded)
        check.equal("success keeps the paused transport", success.transport, .paused)
        check.nil_("success clears pending command", success.pending)
        check.equal("success completion is reported", success.session.completions, [true])
        check.equal("success does not reconnect", success.session.reconnectCount, 0)

        let failure = RegistryRuntime()
        _ = failure.requestPause()
        failure.deliver(.remoteFailed)
        check.equal("failure rolls transport back", failure.transport, .playing)
        check.equal("failure completion is reported", failure.session.completions, [false])
        check.equal("remote failure does not reconnect", failure.session.reconnectCount, 0)

        let reconnect = RegistryRuntime()
        _ = reconnect.requestPause()
        reconnect.deliver(.reconnectRequired)
        check.equal("reconnect runs only after an accepted finish", reconnect.session.reconnectCount, 1)
        check.equal("reconnect-required is a failed completion", reconnect.session.completions, [false])
    }

    check.suite("Matching snapshot then successful finish") {
        let runtime = RegistryRuntime()
        _ = runtime.requestPause()
        let commandID = runtime.pending?.id
        check.notNil("pause is pending before the snapshot", commandID)
        let reconciled = runtime.session.send(
            .transport(.paused),
            source: .enginePlayback,
            revision: 1
        )
        check.check("a matching paused snapshot is accepted", reconciled)
        check.nil_("the snapshot reconciles the pending command", runtime.pending)
        check.equal("the snapshot keeps the optimistic pause", runtime.transport, .paused)
        runtime.deliver(.succeeded)
        check.equal("already-reconciled success still reports the completion", runtime.session.completions, [true])
        check.equal("already-reconciled success does not reconnect", runtime.session.reconnectCount, 0)

        let lateFailure = RegistryRuntime()
        _ = lateFailure.requestPause()
        _ = lateFailure.session.send(
            .transport(.paused),
            source: .enginePlayback,
            revision: 1
        )
        check.nil_("the snapshot reconciles before the late failure", lateFailure.pending)
        lateFailure.deliver(.reconnectRequired)
        check.equal("a late coordinator failure still reports success", lateFailure.session.completions, [true])
        check.equal("a late coordinator failure does not reconnect", lateFailure.session.reconnectCount, 0)
        check.equal("a late coordinator failure does not roll back the confirmed pause", lateFailure.transport, .paused)
        check.nil_("a late coordinator failure does not surface an error notice", lateFailure.session.state.notice)
    }

    check.suite("Cancel in flight restores captured pause") {
        let runtime = RegistryRuntime()
        _ = runtime.requestPause()
        runtime.cancelInFlight()
        runtime.deliver(.succeeded)
        check.equal("cancellation restores the captured transport", runtime.transport, .playing)
        check.nil_("cancellation clears the pending command", runtime.pending)
        check.equal("cancelled work reports failure once", runtime.session.completions, [false])
        check.equal("cancelled work does not reconnect", runtime.session.reconnectCount, 0)
        check.check("a later pause of the same kind is admitted", runtime.requestPause())
        check.equal("the later pause applies optimistic paused transport", runtime.transport, .paused)

        let confirmed = RegistryRuntime()
        _ = confirmed.requestPause()
        let commandID = confirmed.pending?.id
        check.notNil("pause is pending before the snapshot", commandID)
        _ = confirmed.session.send(
            .transport(.paused),
            source: .enginePlayback,
            revision: 1
        )
        check.nil_("the snapshot reconciles the pending command", confirmed.pending)
        confirmed.cancelInFlight()
        check.equal("confirmed cancellation keeps the paused transport", confirmed.transport, .paused)
        check.check("confirmed cancellation reports no completion", confirmed.session.completions.isEmpty)

        let stale = RegistryRuntime()
        _ = stale.requestPause()
        stale.session.restartEngine()
        stale.cancelInFlight()
        check.check("stale cancellation reports no completion", stale.session.completions.isEmpty)
        check.nil_("engine-epoch invalidation already dropped the pending command", stale.pending)
    }

    check.suite("Stale finishes stay inert") {
        let engine = RegistryRuntime()
        _ = engine.requestPause()
        engine.session.restartEngine()
        engine.deliver(.reconnectRequired)
        check.equal("engine-epoch invalidation does not reconnect", engine.session.reconnectCount, 0)
        check.check("engine-epoch invalidation reports no completion", engine.session.completions.isEmpty)

        let account = RegistryRuntime()
        _ = account.requestPause()
        account.invalidateAccount()
        account.deliver(.reconnectRequired)
        check.equal("account-epoch invalidation does not reconnect", account.session.reconnectCount, 0)
        check.check("account-epoch invalidation reports no completion", account.session.completions.isEmpty)

        let superseded = RegistryRuntime()
        check.check("the original pause starts", superseded.requestPause())
        let originalID = superseded.pending?.id
        check.notNil("the original pause is pending", originalID)
        let replacementID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        _ = superseded.session.send(
            .commandStarted(
                PendingPlaybackCommand(
                    id: replacementID,
                    kind: .transport,
                    expectedTransport: .playing,
                    startedAt: spikeDate
                ))
        )
        check.equal("the reducer replacement owns the pending slot", superseded.pending?.id, replacementID)
        check.equal("the replacement updates optimistic transport", superseded.transport, .playing)
        superseded.deliver(.succeeded)
        check.check("the superseded original reports no completion", superseded.session.completions.isEmpty)
        check.equal("the replacement remains pending after the stale finish", superseded.pending?.id, replacementID)
        check.equal("the superseded finish cannot roll back the replacement", superseded.transport, .playing)
        check.check("the original id is not the replacement id", originalID != replacementID)
    }

    check.suite("TCA cancelInFlight diverges from Aural") {
        let runtime = RegistryRuntime()
        check.check("the first pause starts", runtime.requestPause())
        check.check(
            "Aural refuses a second transport command while one is pending; TCA cancellable(id:cancelInFlight: true) would cancel and replace it",
            !runtime.requestPause()
        )
        check.equal("the refused attempt completes immediately as failure", runtime.session.completions, [false])
    }
}
