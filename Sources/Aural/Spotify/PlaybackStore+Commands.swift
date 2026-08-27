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
        _ failure: String,
        expecting expectedPlaybackState: Bool? = nil,
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
            let result = await self.coordinator.performLocal(operation)
            guard !Task.isCancelled, self.accountEpoch == epoch, !self.isTearingDown else { return }
            self.applyCommandOutcome(
                commandID: commandID,
                kind: kind,
                capturedAccountEpoch: epoch,
                capturedEngineEpoch: engineEpoch,
                succeeded: result.isOK,
                failure: failure,
                detailedFailure: "\(failure) (\(result.rawValue))",
                requiresReconnect: result.requiresReconnect,
                completion: completion
            )
        })
    }

    func performRoutedCommand(
        _ failure: String,
        kind: PlaybackCommandKind = .transport,
        expecting expectedPlaybackState: Bool? = nil,
        local: LocalPlaybackOperation,
        remote command: SpotifyConnectCommand,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        performRoutedOperation(
            failure,
            kind: kind,
            expecting: expectedPlaybackState,
            local: local,
            remote: { api, from, to in try await api.send(command, from: from, to: to) },
            completion: completion
        )
    }

    func performRoutedOperation(
        _ failure: String,
        kind: PlaybackCommandKind = .transport,
        expecting expectedPlaybackState: Bool? = nil,
        local: LocalPlaybackOperation,
        remote: @escaping @Sendable (any RemotePlaybackClient, String, String) async throws -> Void,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        switch commandRoute {
        case .local:
            AuralLog.commands.info("Routing \(String(describing: kind), privacy: .public) command locally")
            performCommand(
                failure,
                expecting: expectedPlaybackState,
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
                failure,
                kind: kind,
                expecting: expectedPlaybackState,
                from: from,
                to: to,
                operation: remote,
                completion: completion
            )
        }
    }

    private func performRemoteOperation(
        _ failure: String,
        kind: PlaybackCommandKind,
        expecting expectedPlaybackState: Bool?,
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
            do {
                guard let self else { return }
                try await self.coordinator.performRemoteOperation { remote in
                    try await operation(remote, sourceID, targetID)
                }
                guard !Task.isCancelled, self.accountEpoch == epoch, !self.isTearingDown else { return }
                self.applyCommandOutcome(
                    commandID: commandID,
                    kind: kind,
                    capturedAccountEpoch: epoch,
                    capturedEngineEpoch: engineEpoch,
                    succeeded: true,
                    failure: failure,
                    detailedFailure: failure,
                    requiresReconnect: false,
                    completion: completion
                )
            } catch {
                guard let self, !Task.isCancelled, self.accountEpoch == epoch,
                      !self.isTearingDown else { return }
                self.applyCommandOutcome(
                    commandID: commandID,
                    kind: kind,
                    capturedAccountEpoch: epoch,
                    capturedEngineEpoch: engineEpoch,
                    succeeded: false,
                    failure: failure,
                    detailedFailure: "\(failure): \(error.localizedDescription)",
                    requiresReconnect: false,
                    completion: completion
                )
            }
        })
    }

    /// Local and remote command finishes share this policy so a matching engine snapshot cannot
    /// drop `play` / `togglePlayback` completions, including when the coordinator later fails.
    /// Epoch, teardown, non-transport kinds, and superseded ids stay inert.
    private func applyCommandOutcome(
        commandID: UUID,
        kind: PlaybackCommandKind,
        capturedAccountEpoch: UInt64,
        capturedEngineEpoch: UInt64,
        succeeded: Bool,
        failure: String,
        detailedFailure: String,
        requiresReconnect: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let finished = send(
            .commandFinished(
                id: commandID,
                accepted: succeeded,
                notice: succeeded ? nil : PlaybackNotice(message: failure)
            ),
            source: .command
        )
        switch playbackCommandFollowUp(
            finishAccepted: finished,
            operationSucceeded: succeeded,
            requiresReconnect: requiresReconnect,
            commandKind: kind,
            pendingCommandID: state.pendingCommands[kind]?.id,
            capturedAccountEpoch: capturedAccountEpoch,
            capturedEngineEpoch: capturedEngineEpoch,
            currentAccountEpoch: accountEpoch,
            currentEngineEpoch: engineGeneration,
            isTearingDown: isTearingDown
        ) {
        case .reportSuccess:
            completion(true)
        case let .reportFailure(reconnect):
            showTransientCommandError(detailedFailure)
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
