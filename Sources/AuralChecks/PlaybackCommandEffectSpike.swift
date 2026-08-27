import AuralDomain
import Foundation

/// Deterministic prototypes for issue #18. They replay one representative local pause
/// workflow through `PlaybackReducer.send` acceptance; they do not ship.

private let spikeDate = Date(timeIntervalSince1970: 1_000_000)
private let pauseNoticeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

private enum CommandWorkResult: Equatable, Sendable {
    case succeeded
    case remoteFailed
    case reconnectRequired
}

private struct InFlightCommand: Equatable, Sendable {
    var id: UUID
    var accountEpoch: UInt64
    var cancelled: Bool
}

/// Mirrors `PlaybackStore.send`: reduce, then mirror `engineEpoch` only after acceptance.
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
        engineEpoch: UInt64? = nil
    ) -> Bool {
        let stampedEngineEpoch = engineEpoch ?? engineGeneration
        var next = state
        let accepted = PlaybackReducer.reduce(
            &next,
            envelope: PlaybackEventEnvelope(
                accountEpoch: accountEpoch,
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

    func applyAcceptedFinish(commandID: UUID, result: CommandWorkResult) {
        let succeeded = result == .succeeded
        let finished = send(
            .commandFinished(
                id: commandID,
                accepted: succeeded,
                notice: succeeded ? nil : PlaybackNotice(id: pauseNoticeID, message: "Pause was rejected")
            )
        )
        guard finished else { return }
        completions.append(succeeded)
        if result == .reconnectRequired {
            reconnectCount += 1
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

private protocol PauseCommandRuntime: AnyObject {
    var session: CommandSession { get }
    @discardableResult
    func requestPause() -> Bool
    func deliver(_ result: CommandWorkResult)
    func cancelInFlight()
    func invalidateAccount()
    func restartEngine()
}

extension PauseCommandRuntime {
    var transport: PlaybackTransportState { session.state.transport }
    var pending: PendingPlaybackCommand? { session.state.pendingCommands[.transport] }
    var notice: String? { session.state.notice?.message }
    var reconnects: Int { session.reconnectCount }
    var completions: [Bool] { session.completions }
}

/// Option 1: explicit `Task` tokens keyed like `PlaybackEffectRegistry`.
private final class RegistryRuntime: PauseCommandRuntime {
    let session = CommandSession()
    private var tasks: [UUID: InFlightCommand] = [:]
    private var lastCommandID: UUID?

    func requestPause() -> Bool {
        guard !session.isTearingDown else {
            session.completions.append(false)
            return false
        }
        guard session.state.pendingCommands[.transport] == nil else {
            session.completions.append(false)
            return false
        }
        let commandID = UUID()
        let started = session.send(
            .commandStarted(PendingPlaybackCommand(
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
        tasks[commandID]?.cancelled = true
        tasks[commandID] = InFlightCommand(id: commandID, accountEpoch: session.accountEpoch, cancelled: false)
        lastCommandID = commandID
        return true
    }

    func deliver(_ result: CommandWorkResult) {
        guard let commandID = lastCommandID, let inflight = tasks[commandID] else { return }
        defer { tasks[commandID] = nil }
        guard !inflight.cancelled,
              inflight.accountEpoch == session.accountEpoch,
              !session.isTearingDown
        else { return }
        session.applyAcceptedFinish(commandID: commandID, result: result)
    }

    func cancelInFlight() {
        if let commandID = lastCommandID {
            tasks[commandID]?.cancelled = true
        }
    }

    func invalidateAccount() {
        for key in tasks.keys { tasks[key]?.cancelled = true }
        session.invalidateAccount()
    }

    func restartEngine() {
        session.restartEngine()
    }
}

/// Option 2: a command-specific plan, not a generic `Effect<Action, Error, Result>`.
private final class TinyRunnerRuntime: PauseCommandRuntime {
    let session = CommandSession()
    private var plan: InFlightCommand?

    func requestPause() -> Bool {
        guard !session.isTearingDown, plan == nil, session.state.pendingCommands[.transport] == nil else {
            session.completions.append(false)
            return false
        }
        let commandID = UUID()
        let started = session.send(
            .commandStarted(PendingPlaybackCommand(
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
        plan = InFlightCommand(id: commandID, accountEpoch: session.accountEpoch, cancelled: false)
        return true
    }

    func deliver(_ result: CommandWorkResult) {
        guard let plan else { return }
        self.plan = nil
        guard !plan.cancelled, plan.accountEpoch == session.accountEpoch, !session.isTearingDown else { return }
        session.applyAcceptedFinish(commandID: plan.id, result: result)
    }

    func cancelInFlight() {
        plan?.cancelled = true
        plan = nil
    }

    func invalidateAccount() {
        cancelInFlight()
        session.invalidateAccount()
    }

    func restartEngine() {
        session.restartEngine()
    }
}

/// Option 3: TCA 1.x programming model (`Reduce` returns `Effect`, `.cancellable`, `.cancel`)
/// without importing the package. Actions always enter the reducer; rejected `PlaybackReducer`
/// sends skip dependent effects, matching post-#15 `send(...) -> Bool`.
private final class TCAStyleRuntime: PauseCommandRuntime {
    enum CancelID: Hashable, Sendable {
        case command
    }

    enum Action: Equatable, Sendable {
        case pauseTapped
        case resultDelivered(CommandWorkResult)
        case cancelInFlight
        case accountInvalidated
        case engineRestarted
    }

    struct Effect: Equatable {
        enum Kind: Equatable {
            case none
            case run(CancelID)
            case cancel(CancelID)
        }

        var kind: Kind
        static var none: Self { Self(kind: .none) }
        static func run(id: CancelID, cancelInFlight _: Bool = false) -> Self {
            // `cancelInFlight` is unused on the happy path: Aural refuses a second transport
            // command instead of replacing it. See `tcaCancelInFlightWouldReplace`.
            Self(kind: .run(id))
        }

        static func cancel(id: CancelID) -> Self {
            Self(kind: .cancel(id))
        }
    }

    let session = CommandSession()
    private var inFlight: [CancelID: InFlightCommand] = [:]
    private(set) var lastEffect: Effect = .none
    private var cancelInFlightEnabled = false

    func requestPause() -> Bool {
        reduce(.pauseTapped)
    }

    func deliver(_ result: CommandWorkResult) {
        reduce(.resultDelivered(result))
    }

    func cancelInFlight() {
        reduce(.cancelInFlight)
    }

    func invalidateAccount() {
        reduce(.accountInvalidated)
    }

    func restartEngine() {
        reduce(.engineRestarted)
    }

    @discardableResult
    private func reduce(_ action: Action) -> Bool {
        let effect: Effect
        switch action {
        case .pauseTapped:
            if cancelInFlightEnabled, inFlight[.command] != nil {
                inFlight[.command] = nil
            }
            guard !session.isTearingDown, session.state.pendingCommands[.transport] == nil || cancelInFlightEnabled else {
                session.completions.append(false)
                lastEffect = .none
                return false
            }
            let commandID = UUID()
            let started = session.send(
                .commandStarted(PendingPlaybackCommand(
                    id: commandID,
                    kind: .transport,
                    expectedTransport: .paused,
                    startedAt: spikeDate
                ))
            )
            guard started else {
                session.completions.append(false)
                lastEffect = .none
                return false
            }
            inFlight[.command] = InFlightCommand(
                id: commandID,
                accountEpoch: session.accountEpoch,
                cancelled: false
            )
            effect = .run(id: .command, cancelInFlight: cancelInFlightEnabled)
        case let .resultDelivered(result):
            guard let inflight = inFlight.removeValue(forKey: .command) else {
                lastEffect = .none
                return false
            }
            guard !inflight.cancelled,
                  inflight.accountEpoch == session.accountEpoch,
                  !session.isTearingDown
            else {
                lastEffect = .none
                return false
            }
            session.applyAcceptedFinish(commandID: inflight.id, result: result)
            effect = .none
        case .cancelInFlight:
            inFlight[.command]?.cancelled = true
            inFlight[.command] = nil
            effect = .cancel(id: .command)
        case .accountInvalidated:
            inFlight[.command]?.cancelled = true
            inFlight[.command] = nil
            session.invalidateAccount()
            effect = .cancel(id: .command)
        case .engineRestarted:
            session.restartEngine()
            effect = .none
        }
        lastEffect = effect
        return true
    }

    /// TCA's default `cancellable(id:cancelInFlight: true)` would cancel and replace, unlike Aural.
    func tcaCancelInFlightWouldReplace() -> Bool {
        cancelInFlightEnabled = true
        defer { cancelInFlightEnabled = false }
        _ = requestPause()
        let firstID = inFlight[.command]?.id
        let secondStarted = requestPause()
        let secondID = inFlight[.command]?.id
        return secondStarted && firstID != nil && secondID != nil && firstID != secondID
    }
}

private func runSharedPauseScenarios<Runtime: PauseCommandRuntime>(
    _ check: CheckRunner,
    name: String,
    make: () -> Runtime
) {
    check.suite("\(name): optimistic success") {
        let runtime = make()
        check.check("pause is accepted while idle", runtime.requestPause())
        check.equal("optimistic pause is visible immediately", runtime.transport, .paused)
        runtime.deliver(.succeeded)
        check.equal("success keeps the paused transport", runtime.transport, .paused)
        check.nil_("success clears pending command", runtime.pending)
        check.equal("success completion is reported", runtime.completions, [true])
        check.equal("success does not reconnect", runtime.reconnects, 0)
    }

    check.suite("\(name): remote failure rollback") {
        let runtime = make()
        _ = runtime.requestPause()
        runtime.deliver(.remoteFailed)
        check.equal("failure rolls transport back", runtime.transport, .playing)
        check.equal("failure surfaces a notice", runtime.notice, "Pause was rejected")
        check.equal("failure completion is reported", runtime.completions, [false])
        check.equal("remote failure does not reconnect", runtime.reconnects, 0)
    }

    check.suite("\(name): local reconnect-required") {
        let runtime = make()
        _ = runtime.requestPause()
        runtime.deliver(.reconnectRequired)
        check.equal("reconnect-required rolls transport back", runtime.transport, .playing)
        check.equal("reconnect runs only after an accepted finish", runtime.reconnects, 1)
        check.equal("reconnect-required is a failed completion", runtime.completions, [false])
    }

    check.suite("\(name): cancel in flight") {
        let runtime = make()
        _ = runtime.requestPause()
        runtime.cancelInFlight()
        runtime.deliver(.succeeded)
        check.equal("a cancelled result cannot keep the optimistic pause", runtime.transport, .paused)
        check.notNil("pending command remains until a valid finish or epoch reset", runtime.pending)
        check.check("cancelled work reports no completion", runtime.completions.isEmpty)
        check.equal("cancelled work does not reconnect", runtime.reconnects, 0)
    }

    check.suite("\(name): account-epoch invalidation") {
        let runtime = make()
        _ = runtime.requestPause()
        runtime.invalidateAccount()
        runtime.deliver(.reconnectRequired)
        check.equal("a new account does not inherit pause", runtime.transport, .stopped)
        check.equal("a new account starts signed out", runtime.session.state.session, .signedOut)
        check.check("stale command completion is dropped", runtime.completions.isEmpty)
        check.equal("stale reconnect is not requested", runtime.reconnects, 0)
    }

    check.suite("\(name): rejected send after engine restart") {
        let runtime = make()
        _ = runtime.requestPause()
        let commandID = runtime.pending?.id
        runtime.restartEngine()
        check.nil_("engine restart clears pending commands in the reducer", runtime.pending)
        runtime.deliver(.reconnectRequired)
        check.check("the in-flight id is the one the reducer dropped", commandID != nil)
        check.equal("a rejected finish does not reconnect", runtime.reconnects, 0)
        check.check("a rejected finish reports no completion", runtime.completions.isEmpty)
    }

    check.suite("\(name): second pause is refused") {
        let runtime = make()
        check.check("first pause starts", runtime.requestPause())
        check.check("second pause is refused while pending", !runtime.requestPause())
        check.equal("the refused attempt completes immediately as failure", runtime.completions, [false])
        runtime.deliver(.succeeded)
        check.equal("the original pause still succeeds", runtime.completions, [false, true])
    }
}

func runPlaybackCommandEffectSpikeChecks(_ check: CheckRunner) {
    runSharedPauseScenarios(check, name: "Registry runtime") { RegistryRuntime() }
    runSharedPauseScenarios(check, name: "Tiny command runner") { TinyRunnerRuntime() }
    runSharedPauseScenarios(check, name: "TCA-style runtime") { TCAStyleRuntime() }

    check.suite("TCA cancelInFlight diverges from Aural") {
        let runtime = TCAStyleRuntime()
        check.check(
            "TCA cancelInFlight: true would replace the in-flight pause instead of refusing it",
            runtime.tcaCancelInFlightWouldReplace()
        )
    }

    check.suite("Connect queue watermark stays outside command effects") {
        var watermark = ConnectQueueCallbackWatermark()
        check.check(
            "a newer queue callback is accepted",
            watermark.accept(generation: 2, revision: 1, engineEpoch: 1)
        )
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready, transport: .playing)
        _ = PlaybackReducer.reduce(
            &state,
            envelope: PlaybackEventEnvelope(
                accountEpoch: 1,
                engineEpoch: 2,
                source: .engineConnection,
                revision: 1,
                receivedAt: spikeDate,
                event: .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil))
            )
        )
        check.equal("reducer engine epoch adoption does not reset the queue watermark", watermark.generation, 2)
        check.equal("queue callback revision survives a command-unrelated engine bump", watermark.revision, 1)
    }
}
