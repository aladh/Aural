import Testing
import SpottyDomain
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
        case .reconnectAfterReconciledSuccess:
            completions.append(true)
            reconnectCount += 1
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

@Suite("Playback Command Effect Spike")
struct PlaybackCommandEffectSpikeTests {
    @Test
    func testPlaybackCommandEffectSpike() {
        do {
            let success = RegistryRuntime()
            #expect((success.requestPause()) == true, "pause is accepted while idle")
            #expect((success.transport) == (.paused), "optimistic pause is visible immediately")
            success.deliver(.succeeded)
            #expect((success.transport) == (.paused), "success keeps the paused transport")
            #expect((success.pending) == nil, "success clears pending command")
            #expect((success.session.completions) == ([true]), "success completion is reported")
            #expect((success.session.reconnectCount) == (0), "success does not reconnect")

            let failure = RegistryRuntime()
            _ = failure.requestPause()
            failure.deliver(.remoteFailed)
            #expect((failure.transport) == (.playing), "failure rolls transport back")
            #expect((failure.session.completions) == ([false]), "failure completion is reported")
            #expect((failure.session.reconnectCount) == (0), "remote failure does not reconnect")

            let reconnect = RegistryRuntime()
            _ = reconnect.requestPause()
            reconnect.deliver(.reconnectRequired)
            #expect((reconnect.session.reconnectCount) == (1), "reconnect runs only after an accepted finish")
            #expect((reconnect.session.completions) == ([false]), "reconnect-required is a failed completion")
        }

        do {
            let runtime = RegistryRuntime()
            _ = runtime.requestPause()
            let commandID = runtime.pending?.id
            #expect((commandID) != nil, "pause is pending before the snapshot")
            let reconciled = runtime.session.send(
                .transport(.paused),
                source: .enginePlayback,
                revision: 1
            )
            #expect((reconciled) == true, "a matching paused snapshot is accepted")
            #expect((runtime.pending) == nil, "the snapshot reconciles the pending command")
            #expect((runtime.transport) == (.paused), "the snapshot keeps the optimistic pause")
            runtime.deliver(.succeeded)
            #expect(
                (runtime.session.completions) == ([true]), "already-reconciled success still reports the completion")
            #expect((runtime.session.reconnectCount) == (0), "already-reconciled success does not reconnect")

            let lateFailure = RegistryRuntime()
            _ = lateFailure.requestPause()
            _ = lateFailure.session.send(
                .transport(.paused),
                source: .enginePlayback,
                revision: 1
            )
            #expect((lateFailure.pending) == nil, "the snapshot reconciles before the late failure")
            lateFailure.deliver(.reconnectRequired)
            #expect(
                (lateFailure.session.completions) == ([true]),
                "a late reconnect-required failure keeps the reconciled completion")
            #expect((lateFailure.session.reconnectCount) == (1), "a late reconnect-required failure still reconnects")
            #expect(
                (lateFailure.transport) == (.paused),
                "a late coordinator failure does not roll back the confirmed pause")
            #expect(
                (lateFailure.session.state.notice) == nil, "a late coordinator failure does not surface an error notice"
            )
        }

        do {
            let runtime = RegistryRuntime()
            _ = runtime.requestPause()
            runtime.cancelInFlight()
            runtime.deliver(.succeeded)
            #expect((runtime.transport) == (.playing), "cancellation restores the captured transport")
            #expect((runtime.pending) == nil, "cancellation clears the pending command")
            #expect((runtime.session.completions) == ([false]), "cancelled work reports failure once")
            #expect((runtime.session.reconnectCount) == (0), "cancelled work does not reconnect")
            #expect((runtime.requestPause()) == true, "a later pause of the same kind is admitted")
            #expect((runtime.transport) == (.paused), "the later pause applies optimistic paused transport")

            let confirmed = RegistryRuntime()
            _ = confirmed.requestPause()
            let commandID = confirmed.pending?.id
            #expect((commandID) != nil, "pause is pending before the snapshot")
            _ = confirmed.session.send(
                .transport(.paused),
                source: .enginePlayback,
                revision: 1
            )
            #expect((confirmed.pending) == nil, "the snapshot reconciles the pending command")
            confirmed.cancelInFlight()
            #expect((confirmed.transport) == (.paused), "confirmed cancellation keeps the paused transport")
            #expect((confirmed.session.completions.isEmpty) == true, "confirmed cancellation reports no completion")

            let stale = RegistryRuntime()
            _ = stale.requestPause()
            stale.session.restartEngine()
            stale.cancelInFlight()
            #expect((stale.session.completions.isEmpty) == true, "stale cancellation reports no completion")
            #expect((stale.pending) == nil, "engine-epoch invalidation already dropped the pending command")
        }

        do {
            let engine = RegistryRuntime()
            _ = engine.requestPause()
            engine.session.restartEngine()
            engine.deliver(.reconnectRequired)
            #expect((engine.session.reconnectCount) == (0), "engine-epoch invalidation does not reconnect")
            #expect((engine.session.completions.isEmpty) == true, "engine-epoch invalidation reports no completion")

            let account = RegistryRuntime()
            _ = account.requestPause()
            account.invalidateAccount()
            account.deliver(.reconnectRequired)
            #expect((account.session.reconnectCount) == (0), "account-epoch invalidation does not reconnect")
            #expect((account.session.completions.isEmpty) == true, "account-epoch invalidation reports no completion")

            let superseded = RegistryRuntime()
            #expect((superseded.requestPause()) == true, "the original pause starts")
            let originalID = superseded.pending?.id
            #expect((originalID) != nil, "the original pause is pending")
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
            #expect((superseded.pending?.id) == (replacementID), "the reducer replacement owns the pending slot")
            #expect((superseded.transport) == (.playing), "the replacement updates optimistic transport")
            superseded.deliver(.succeeded)
            #expect((superseded.session.completions.isEmpty) == true, "the superseded original reports no completion")
            #expect(
                (superseded.pending?.id) == (replacementID), "the replacement remains pending after the stale finish")
            #expect((superseded.transport) == (.playing), "the superseded finish cannot roll back the replacement")
            #expect((originalID != replacementID) == true, "the original id is not the replacement id")
        }

        do {
            let runtime = RegistryRuntime()
            #expect((runtime.requestPause()) == true, "the first pause starts")
            #expect(
                (!runtime.requestPause()) == true,
                "Spotty refuses a second transport command while one is pending; TCA cancellable(id:cancelInFlight: true) would cancel and replace it"
            )
            #expect((runtime.session.completions) == ([false]), "the refused attempt completes immediately as failure")
        }
    }
}
