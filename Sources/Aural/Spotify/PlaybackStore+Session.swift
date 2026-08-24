//
//  PlaybackStore+Session.swift
//  Aural
//
//  Compatibility actions that delegate account lifecycle to AccountStore.
//

import AuralDomain
import Foundation

extension PlaybackStore {
    func restore() async {
        await accountStore.restore()
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
        accountEpoch &+= 1
        engineGeneration &+= 1
        lastPlaybackRevision = 0
        lastQueueRevision = 0
        lastConnectionRevision = 0
        lastDevicesRevision = 0
        catalogSession.update(accountEpoch: accountEpoch, isAvailable: false)
        effects.cancelAccountScoped()
        hasReceivedPlaybackSnapshot = false
        catalog.reset()
        history.reset()
        shuffleHistoryCache = [:]
        send(.reset(session: cumulative.finalPhase), source: .account)

        let accountTask = accountStore.beginEndSession(
            clearGrant: cumulative.clearGrant,
            finalPhase: cumulative.finalPhase
        )
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
        var appliedIntent = await accountTask.value
        accountEpoch = accountStore.epoch
        catalogSession.update(accountEpoch: accountEpoch, isAvailable: false)
        await queueService.reset(accountEpoch: accountEpoch)
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
        isTearingDown = true
        accountEpoch &+= 1
        engineGeneration &+= 1
        lastPlaybackRevision = 0
        lastQueueRevision = 0
        lastConnectionRevision = 0
        lastDevicesRevision = 0
        catalogSession.update(accountEpoch: accountEpoch, isAvailable: false)
        effects.cancelAccountScoped()
        send(.reset(session: .signedOut), source: .account)
        await accountStore.shutdownForTermination()
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
