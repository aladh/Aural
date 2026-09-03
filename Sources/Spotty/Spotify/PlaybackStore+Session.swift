//
//  PlaybackStore+Session.swift
//  Spotty
//
//  Compatibility actions that delegate account lifecycle to AccountStore.
//

import SpottyDomain
import Foundation

extension PlaybackStore {
    func restore() async {
        guard terminationGate.allowsCommands else { return }
        startLifetimeEffectsIfNeeded()
        let queueServiceBootstrap = effects.settlement(of: .queueServiceBootstrap)
        let preferencesRestore = effects.settlement(of: .preferencesRestore)
        await queueServiceBootstrap?.wait()
        guard terminationGate.allowsCommands else { return }
        await accountStore.restore()
        await preferencesRestore?.wait()
    }

    func connect() {
        guard !isTearingDown else { return }
        accountStore.connect()
    }

    func cancelConnect() {
        accountStore.cancelConnect()
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

    func endSession(clearGrant: Bool, finalPhase: Phase) async {
        guard terminationGate.allowsCommands else { return }
        feedback.dismiss()
        let requested = SessionTeardownIntent(clearGrant: clearGrant, finalPhase: finalPhase)
        let shouldStart = teardown.request(requested)
        let cumulative = teardown.intent ?? requested

        if !shouldStart {
            // Upgrade the visible result immediately, but keep the existing epoch and teardown.
            send(.reset(session: cumulative.finalPhase), source: .account)
            accountStore.upgradeActiveEndSession(
                clearGrant: cumulative.clearGrant,
                finalPhase: cumulative.finalPhase
            )
            if let teardownTask { await teardownTask.value }
            return
        }

        isTearingDown = true
        // Advance AccountStore.epoch before any reducer send, catalog update, queue reset,
        // or effect invalidation so every observer uses that already-advanced identity.
        let accountTask = accountStore.beginEndSession(
            clearGrant: cumulative.clearGrant,
            finalPhase: cumulative.finalPhase
        )
        engineGeneration &+= 1
        connectQueueCallback.reset()
        queueInspectorOrderingVersion = 0
        catalogSession.update(accountEpoch: accountEpoch, isAvailable: false)
        effects.cancelAccountScoped()
        hasReceivedPlaybackSnapshot = false
        catalog.reset()
        history.reset()
        queueMutation = nil
        queueReplacementToken = nil
        shuffleHistoryCache = [:]
        send(.reset(session: cumulative.finalPhase), source: .account)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performEndSession(accountTask: accountTask)
        }
        teardownTask = task
        await task.value
    }

    private func performEndSession(
        accountTask: Task<SessionTeardownIntent, Never>
    ) async {
        await queueService.reset(accountEpoch: accountEpoch)
        var appliedIntent = await accountTask.value
        await environment.preferences.setShuffleHistory([:])

        var clearedRemoteDevice = false
        while let desiredIntent = teardown.intent {
            if desiredIntent != appliedIntent {
                appliedIntent = await accountStore.reconcileCompletedEndSession(
                    applied: appliedIntent,
                    desired: desiredIntent
                )
                continue
            }

            if desiredIntent.clearGrant, !clearedRemoteDevice {
                lastRemoteDeviceID = nil
                await environment.preferences.setLastRemoteDeviceID(nil)
                clearedRemoteDevice = true
                continue
            }

            // There is no suspension between this final comparison and releasing the gate, so a
            // request either coalesces above or starts a genuinely new session boundary afterward.
            let completed = teardown.complete() ?? desiredIntent
            send(.session(completed.finalPhase), source: .account)
            teardownTask = nil
            isTearingDown = false
            return
        }

        // Defensive recovery for an impossible externally-cleared coalescer.
        teardownTask = nil
        isTearingDown = false
    }

    /// Performs the one process-termination shutdown. Streaming credentials remain intact for the
    /// next launch; account logout is a separate operation.
    func shutdownForTermination() async {
        guard terminationGate.begin() else { return }
        guard !isTearingDown else { return }
        feedback.dismiss()
        isTearingDown = true
        let staleConnectionTask = accountStore.prepareShutdownForTermination()
        engineGeneration &+= 1
        connectQueueCallback.reset()
        queueInspectorOrderingVersion = 0
        catalogSession.update(accountEpoch: accountEpoch, isAvailable: false)
        effects.cancelAccountScoped()
        effects.cancel(.engineEvents)
        effects.cancel(.grantRevocations)
        effects.cancel(.lifecycle)
        send(.reset(session: .signedOut), source: .account)
        await accountStore.completeShutdownForTermination(staleConnectionTask: staleConnectionTask)
    }

    func clearCurrentTrackMetadata() {
        effects.cancel(.trackMetadata)
        guard let track = state.currentTrack else { return }
        setPresentation(
            track: CurrentTrack(uri: track.uri),
            transport: state.transport,
            timing: PlaybackTiming(anchoredAt: environment.clock.now()),
            source: .metadata
        )
    }
}
