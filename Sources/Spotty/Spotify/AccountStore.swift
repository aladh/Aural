import SpottyDomain
import Foundation
import Observation
import OSLog

/// Owns the complete account lifecycle. Every suspended operation is tied to both a generation
/// and account epoch, so logout/revocation wins even when authorization or engine startup returns
/// late.
@MainActor
@Observable
final class AccountStore {
    private(set) var phase: PlaybackSessionPhase = .signedOut {
        didSet {
            guard oldValue != phase else { return }
            let from = sessionPhaseLogLabel(oldValue)
            let to = sessionPhaseLogLabel(phase)
            SpottyLog.account.info(
                "Session phase changed: \(from, privacy: .public) -> \(to, privacy: .public); epoch=\(self.epoch, privacy: .public)"
            )
            onPhaseChange?(phase)
        }
    }
    /// Sole writable account-epoch owner. `PlaybackStore.accountEpoch` projects this value;
    /// `PlaybackState.accountEpoch` is reducer-owned accepted snapshot state, not a second
    /// imperative counter.
    private(set) var epoch: UInt64 = 1

    @ObservationIgnored private let environment: PlaybackEnvironment
    @ObservationIgnored private let coordinator: PlaybackCoordinator
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration: UInt64 = 0
    @ObservationIgnored private var teardown = SessionTeardownCoalescer()
    @ObservationIgnored private var teardownTask: Task<SessionTeardownIntent, Never>?
    @ObservationIgnored var onPhaseChange: ((PlaybackSessionPhase) -> Void)?
    @ObservationIgnored var onReady: (() -> Void)?

    init(environment: PlaybackEnvironment, coordinator: PlaybackCoordinator) {
        self.environment = environment
        self.coordinator = coordinator
    }

    func restore() async {
        guard !teardown.isActive, phase != .ready, connectionTask == nil else { return }
        let interval = SpottyLog.accountSignposter.beginInterval("Restore")
        defer { SpottyLog.accountSignposter.endInterval("Restore", interval) }
        guard let task = startConnection(interactive: false) else { return }
        await task.value
    }

    func connect() {
        guard !teardown.isActive, phase != .ready, connectionTask == nil else { return }
        _ = startConnection(interactive: true)
    }

    func cancelConnect() {
        guard phase == .authorizing else { return }
        connectionGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        phase = .signedOut
    }

    func logout() async {
        await endSession(clearGrant: true, finalPhase: .signedOut)
    }

    func handleGrantRevocation() async {
        await endSession(
            clearGrant: false,
            finalPhase: .failed("Your Spotify session expired. Sign in again.")
        )
    }

    func receiveEngineConnection(_ session: PlaybackSessionPhase?) {
        guard !teardown.isActive, connectionTask == nil else { return }
        if let session {
            phase = session
        }
    }

    func endSession(clearGrant: Bool, finalPhase: PlaybackSessionPhase) async {
        _ = await beginEndSession(clearGrant: clearGrant, finalPhase: finalPhase).value
    }

    /// Starts one account teardown or merges into the teardown already in flight. Returning the
    /// shared task lets PlaybackStore keep its wider presentation cleanup in the same lifetime.
    @discardableResult
    func beginEndSession(
        clearGrant: Bool,
        finalPhase: PlaybackSessionPhase
    ) -> Task<SessionTeardownIntent, Never> {
        let requested = SessionTeardownIntent(clearGrant: clearGrant, finalPhase: finalPhase)
        let shouldStart = teardown.request(requested)
        let cumulative = teardown.intent ?? requested

        if !shouldStart, let teardownTask {
            phase = cumulative.finalPhase
            return teardownTask
        }

        let staleTask = invalidateAccountIdentity()
        phase = cumulative.finalPhase

        let task = Task { [weak self] in
            guard let self else { return cumulative }
            return await self.performEndSession(staleConnectionTask: staleTask, initialIntent: cumulative)
        }
        teardownTask = task
        return task
    }

    /// Propagates a stronger request from PlaybackStore while the account operation is suspended.
    /// False means the account-level teardown already completed; PlaybackStore will reconcile the
    /// upgrade without starting a second engine shutdown or account epoch.
    @discardableResult
    func upgradeActiveEndSession(
        clearGrant: Bool,
        finalPhase: PlaybackSessionPhase
    ) -> Bool {
        guard teardown.isActive, teardownTask != nil else { return false }
        let requested = SessionTeardownIntent(clearGrant: clearGrant, finalPhase: finalPhase)
        _ = teardown.request(requested)
        phase = (teardown.intent ?? requested).finalPhase
        return true
    }

    /// Applies an intent that became stronger after the account-level task completed but while
    /// PlaybackStore was still clearing presentation state. This deliberately does not advance the
    /// epoch or shut the engine down again.
    func reconcileCompletedEndSession(
        applied: SessionTeardownIntent,
        desired: SessionTeardownIntent
    ) async -> SessionTeardownIntent {
        let resolved = applied.merging(desired)
        if resolved.clearGrant && !applied.clearGrant {
            await environment.account.clear()
        }
        phase = resolved.finalPhase
        return resolved
    }

    private func performEndSession(
        staleConnectionTask: Task<Void, Never>?,
        initialIntent: SessionTeardownIntent
    ) async -> SessionTeardownIntent {
        let interval = SpottyLog.accountSignposter.beginInterval("Teardown")
        defer { SpottyLog.accountSignposter.endInterval("Teardown", interval) }
        if let staleConnectionTask { await staleConnectionTask.value }

        _ = await coordinator.shutdownEngine()
        await coordinator.cleanupEngine()
        await coordinator.clearStreamingCredentials()
        var resolved = teardown.intent ?? initialIntent
        if resolved.clearGrant {
            await environment.account.clear()
            resolved = teardown.intent ?? resolved
        }

        let completed = teardown.complete() ?? resolved
        phase = completed.finalPhase
        teardownTask = nil
        return completed
    }

    /// The only mutation of `epoch`. A new account lifetime starts here so in-flight work
    /// stamped with the previous value is rejected.
    func advanceEpoch() {
        epoch &+= 1
    }

    /// Advances account identity and cancels in-flight connection work. Returns the cancelled
    /// connection task so the caller can await it after presentation teardown.
    @discardableResult
    func invalidateAccountIdentity() -> Task<Void, Never>? {
        advanceEpoch()
        connectionGeneration &+= 1
        let staleTask = connectionTask
        connectionTask = nil
        staleTask?.cancel()
        return staleTask
    }

    /// Invalidates account identity without waiting for engine shutdown so presentation
    /// teardown can observe the new epoch first. Streaming credentials stay intact.
    @discardableResult
    func prepareShutdownForTermination() -> Task<Void, Never>? {
        let staleTask = invalidateAccountIdentity()
        phase = .signedOut
        return staleTask
    }

    func completeShutdownForTermination(staleConnectionTask: Task<Void, Never>?) async {
        if let staleConnectionTask { await staleConnectionTask.value }
        _ = await coordinator.shutdownEngine()
        await coordinator.cleanupEngine()
        phase = .signedOut
    }

    @discardableResult
    private func startConnection(interactive: Bool) -> Task<Void, Never>? {
        guard connectionTask == nil else { return connectionTask }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let operationEpoch = epoch
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runConnection(
                interactive: interactive,
                generation: generation,
                epoch: operationEpoch
            )
            if self.isCurrent(generation: generation, epoch: operationEpoch) {
                self.connectionTask = nil
            }
        }
        connectionTask = task
        return task
    }

    private func runConnection(interactive: Bool, generation: UInt64, epoch: UInt64) async {
        let hasGrant = await environment.account.hasGrant()
        guard isCurrent(generation: generation, epoch: epoch) else { return }

        if hasGrant {
            await restoreGrant(generation: generation, epoch: epoch)
        } else if interactive {
            await performInteractiveConnect(generation: generation, epoch: epoch)
        } else {
            phase = .signedOut
        }
    }

    private func restoreGrant(generation: UInt64, epoch: UInt64) async {
        if await initializePlayer(generation: generation, epoch: epoch, reportFailure: false) {
            return
        }
        guard isCurrent(generation: generation, epoch: epoch) else { return }

        do {
            let token = try await environment.account.accessToken()
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            let code = await coordinator.authorizeStreaming(with: token)
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            guard code == 0 else {
                phase = .failed(LiveSpotifyError.streamingAuthorization(code).localizedDescription)
                return
            }
            await coordinator.cleanupEngine()
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            _ = await initializePlayer(generation: generation, epoch: epoch, reportFailure: true)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func performInteractiveConnect(generation: UInt64, epoch: UInt64) async {
        phase = .authorizing
        do {
            let tokens = try await environment.account.authorizeInteractively()
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            try await environment.account.adopt(tokens)
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            phase = .connecting

            let code = await coordinator.authorizeStreaming(with: tokens.accessToken)
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            guard code == 0 else { throw LiveSpotifyError.streamingAuthorization(code) }
            _ = await initializePlayer(generation: generation, epoch: epoch, reportFailure: true)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    private func initializePlayer(
        generation: UInt64,
        epoch: UInt64,
        reportFailure: Bool
    ) async -> Bool {
        let interval = SpottyLog.accountSignposter.beginInterval("Engine initialization")
        defer { SpottyLog.accountSignposter.endInterval("Engine initialization", interval) }
        guard isCurrent(generation: generation, epoch: epoch) else { return false }
        phase = .connecting
        await coordinator.configureDeviceIdentity()
        await coordinator.configureHighQualityPlayback()
        guard isCurrent(generation: generation, epoch: epoch) else { return false }
        do {
            try environment.audioOutput.prepareForPlayback()
        } catch {
            guard isCurrent(generation: generation, epoch: epoch) else { return false }
            SpottyLog.audio.error("Audio output preparation failed")
            phase = .failed(error.localizedDescription)
            return false
        }
        let result = await coordinator.initializeEngine()
        guard isCurrent(generation: generation, epoch: epoch) else { return false }

        if result.isOK {
            phase = .ready
            onReady?()
            return true
        }
        if reportFailure {
            phase = .failed("Spotty Connect could not start (\(result.rawValue))")
        }
        return false
    }

    private func isCurrent(generation: UInt64, epoch: UInt64) -> Bool {
        !Task.isCancelled && connectionGeneration == generation && self.epoch == epoch
    }
}

/// Public log category for a session phase. Failed phases keep their user-facing text off logs.
func sessionPhaseLogLabel(_ phase: PlaybackSessionPhase) -> String {
    switch phase {
    case .signedOut: "signedOut"
    case .authorizing: "authorizing"
    case .connecting: "connecting"
    case .ready: "ready"
    case .recovering: "recovering"
    case .failed: "failed"
    }
}
