//
//  PlaybackStore+Commands.swift
//  Aural
//
//  Command routing, outcomes, rollback, and notices.
//

import AuralDomain
import Foundation
import OSLog

extension PlaybackStore {
    func performCommand(
        _ action: String,
        expecting expectedPlaybackState: Bool? = nil,
        expectedTiming: PlaybackTiming? = nil,
        expectedTrack: CurrentTrack? = nil,
        operation: LocalPlaybackOperation,
        kind: PlaybackCommandKind = .transport,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        guard !isTearingDown, terminationGate.allowsCommands else {
            completion(false)
            return
        }
        guard state.pendingCommands[kind] == nil else {
            completion(false)
            return
        }
        let commandID = UUID()
        let epoch = accountEpoch
        let engineEpoch = engineGeneration
        let started = send(
            .commandStarted(PendingPlaybackCommand(
                id: commandID,
                kind: kind,
                expectedTransport: expectedPlaybackState.map { $0 ? .playing : .paused },
                expectedTiming: expectedTiming,
                expectedTrack: expectedTrack,
                startedAt: environment.clock.now()
            )),
            source: .command
        )
        guard started else {
            completion(false)
            return
        }
        let effectID = PlaybackEffectID.command(commandID)
        effects.replace(effectID, with: Task { [weak self] in
            defer { self?.effects.complete(effectID) }
            guard let self else { return }
            do {
                let outcome = try await self.coordinator.performLocalCommand(operation)
                guard !Task.isCancelled, self.accountEpoch == epoch, !self.isTearingDown else { return }
                self.applyCommandOutcome(
                    commandID: commandID,
                    kind: kind,
                    capturedAccountEpoch: epoch,
                    capturedEngineEpoch: engineEpoch,
                    outcome: outcome,
                    action: action,
                    completion: completion
                )
            } catch {
                return
            }
        })
    }

    func performRoutedCommand(
        _ action: String,
        kind: PlaybackCommandKind = .transport,
        expecting expectedPlaybackState: Bool? = nil,
        expectedTiming: PlaybackTiming? = nil,
        expectedTrack: CurrentTrack? = nil,
        local: LocalPlaybackOperation,
        remote command: SpotifyConnectCommand,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        performRoutedOperation(
            action,
            kind: kind,
            expecting: expectedPlaybackState,
            expectedTiming: expectedTiming,
            expectedTrack: expectedTrack,
            local: local,
            remote: { api, from, to in try await api.send(command, from: from, to: to) },
            completion: completion
        )
    }

    func performRoutedOperation(
        _ action: String,
        kind: PlaybackCommandKind = .transport,
        expecting expectedPlaybackState: Bool? = nil,
        expectedTiming: PlaybackTiming? = nil,
        expectedTrack: CurrentTrack? = nil,
        local: LocalPlaybackOperation,
        remote: @escaping @Sendable (any RemotePlaybackClient, String, String) async throws -> Void,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        switch commandRoute {
        case .local:
            AuralLog.commands.info("Routing \(String(describing: kind), privacy: .public) command locally")
            performCommand(
                action,
                expecting: expectedPlaybackState,
                expectedTiming: expectedTiming,
                expectedTrack: expectedTrack,
                operation: local,
                kind: kind,
                completion: completion
            )
        case .waitingForLocalIdentity:
            AuralLog.commands.notice("Command delayed while local Connect identity is unavailable")
            showTransientCommandError("Aural is still joining Spotify Connect.")
            completion(false)
        case let .remote(from, to):
            AuralLog.commands.info(
                "Routing \(String(describing: kind), privacy: .public) command remotely; source=\(from, privacy: .private(mask: .hash)); target=\(to, privacy: .private(mask: .hash))"
            )
            performRemoteOperation(
                action,
                kind: kind,
                expecting: expectedPlaybackState,
                expectedTiming: expectedTiming,
                expectedTrack: expectedTrack,
                from: from,
                to: to,
                operation: remote,
                completion: completion
            )
        }
    }

    private func performRemoteOperation(
        _ action: String,
        kind: PlaybackCommandKind,
        expecting expectedPlaybackState: Bool?,
        expectedTiming: PlaybackTiming?,
        expectedTrack: CurrentTrack?,
        from sourceID: String,
        to targetID: String,
        operation: @escaping @Sendable (any RemotePlaybackClient, String, String) async throws -> Void,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard !isTearingDown, terminationGate.allowsCommands else {
            completion(false)
            return
        }
        guard state.pendingCommands[kind] == nil else {
            completion(false)
            return
        }
        let commandID = UUID()
        let epoch = accountEpoch
        let engineEpoch = engineGeneration
        let started = send(
            .commandStarted(PendingPlaybackCommand(
                id: commandID,
                kind: kind,
                expectedTransport: expectedPlaybackState.map { $0 ? .playing : .paused },
                expectedTiming: expectedTiming,
                expectedTrack: expectedTrack,
                startedAt: environment.clock.now()
            )),
            source: .command
        )
        guard started else {
            completion(false)
            return
        }
        let effectID = PlaybackEffectID.command(commandID)
        effects.replace(effectID, with: Task { [weak self] in
            defer { self?.effects.complete(effectID) }
            guard let self else { return }
            do {
                let outcome = try await self.coordinator.performRemoteCommand { remote in
                    try await operation(remote, sourceID, targetID)
                }
                guard !Task.isCancelled, self.accountEpoch == epoch, !self.isTearingDown else { return }
                self.applyCommandOutcome(
                    commandID: commandID,
                    kind: kind,
                    capturedAccountEpoch: epoch,
                    capturedEngineEpoch: engineEpoch,
                    outcome: outcome,
                    action: action,
                    completion: completion
                )
            } catch {
                return
            }
        })
    }

    /// Local and remote command finishes share this policy so a matching engine snapshot cannot
    /// drop `play` / `togglePlayback` completions, including when the coordinator later fails.
    /// The finished command's resolution is captured before `commandFinished` so follow-up can
    /// treat consume-only reducer acceptance as confirmed success or superseded inertness.
    /// Epoch, teardown, non-transport kinds, and unknown ids stay inert.
    private func applyCommandOutcome(
        commandID: UUID,
        kind: PlaybackCommandKind,
        capturedAccountEpoch: UInt64,
        capturedEngineEpoch: UInt64,
        outcome: Result<Void, PlaybackCommandFailure>,
        action: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let succeeded: Bool
        let requiresReconnect: Bool
        let notice: PlaybackNotice?
        switch outcome {
        case .success:
            succeeded = true
            requiresReconnect = false
            notice = nil
        case let .failure(failure):
            succeeded = false
            requiresReconnect = failure == .reconnectRequired
            notice = PlaybackNotice(message: action)
        }
        let capturedResolution = state.transportCommandResolutions[commandID]
        let finished = send(
            .commandFinished(
                id: commandID,
                accepted: succeeded,
                notice: notice
            ),
            source: .command,
            engineEpoch: capturedEngineEpoch,
            accountEpoch: capturedAccountEpoch
        )
        switch playbackCommandFollowUp(
            finishAccepted: finished,
            operationSucceeded: succeeded,
            requiresReconnect: requiresReconnect,
            commandKind: kind,
            pendingCommandID: state.pendingCommands[kind]?.id,
            finishedCommandResolution: capturedResolution,
            capturedAccountEpoch: capturedAccountEpoch,
            capturedEngineEpoch: capturedEngineEpoch,
            currentAccountEpoch: accountEpoch,
            currentEngineEpoch: engineGeneration,
            isTearingDown: isTearingDown
        ) {
        case .reportSuccess:
            completion(true)
        case let .reportFailure(reconnect):
            if let notice {
                showTransientCommandError(notice.message)
            }
            completion(false)
            if reconnect {
                connect()
            }
        case .inert:
            break
        }
    }

    func showTransientCommandError(_ message: String) {
        setNotice(message)
        effects.replace(.commandError, with: Task { [weak self] in
            try? await self?.environment.clock.sleep(seconds: 4)
            guard !Task.isCancelled else { return }
            self?.setNotice(nil)
        })
    }

}
