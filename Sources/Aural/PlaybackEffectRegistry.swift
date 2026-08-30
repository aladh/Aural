import Foundation

enum PlaybackEffectID: Hashable {
    case engineEvents
    case grantRevocations
    case lifecycle
    case preferencesRestore
    case catalogLoad
    case positionRefresh
    case queueSnapshot
    case connectQueueAccept
    case queueReplacement
    case queueRefresh
    case trackMetadata
    case commandError
    case command(UUID)
    case queueCommand(UUID)

    var isAccountScoped: Bool {
        switch self {
        case .engineEvents, .grantRevocations, .lifecycle:
            false
        default:
            true
        }
    }
}

/// One owner for every store-level asynchronous lifetime. Replacing a named effect cancels the
/// superseded task; account teardown can invalidate all account work in one operation.
///
/// Transport commands use unique `.command(UUID)` tokens, so this is lifetime ownership rather than
/// kind-level cancel-in-flight. A second pause is refused by the pending-command gate, not by
/// replacing an in-flight token. `replace` may supply a MainActor `onCancel` so ordinary
/// command-token cancellation can settle reducer state before the task resumes. Completing a
/// cancelled or replaced task must not drop a newer token. Sequential Add to Queue keeps unique
/// `.queueCommand(UUID)` tokens so ordered multi-add is not cancelled. Authoritative Connect
/// `set_queue` replacement uses one `.queueReplacement` lifetime plus a MainActor request token: a
/// second removal is refused while one is in flight, because cancellation cannot undo a
/// `set_queue` Spotify already accepted.
/// See `docs/ADR-003-playback-command-effects.md`.
@MainActor
final class PlaybackEffectRegistry {
    private var tasks: [PlaybackEffectID: Task<Void, Never>] = [:]
    private var cancellationHandlers: [PlaybackEffectID: @MainActor () -> Void] = [:]

    func replace(
        _ id: PlaybackEffectID,
        with task: Task<Void, Never>,
        onCancel: (@MainActor () -> Void)? = nil
    ) {
        tasks[id]?.cancel()
        tasks[id] = task
        cancellationHandlers[id] = onCancel
    }

    func cancel(_ id: PlaybackEffectID) {
        let handler = cancellationHandlers.removeValue(forKey: id)
        guard let task = tasks.removeValue(forKey: id) else { return }
        handler?()
        task.cancel()
    }

    /// Drops this token only when the completing task still owns it. A cancelled or
    /// replaced task must not clear a newer registration.
    func complete(_ id: PlaybackEffectID) {
        guard !Task.isCancelled else { return }
        cancellationHandlers.removeValue(forKey: id)
        tasks[id] = nil
    }

    func cancelAccountScoped() {
        let ids = tasks.keys.filter(\.isAccountScoped)
        for id in ids { cancel(id) }
    }
}
