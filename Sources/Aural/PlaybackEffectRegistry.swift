import Foundation

enum PlaybackEffectID: Hashable {
    case engineEvents
    case grantRevocations
    case lifecycle
    case preferencesRestore
    case catalogLoad
    case positionRefresh
    case queueSnapshot
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
/// replacing an in-flight token. See `docs/ADR-003-playback-command-effects.md`.
@MainActor
final class PlaybackEffectRegistry {
    private var tasks: [PlaybackEffectID: Task<Void, Never>] = [:]

    func replace(_ id: PlaybackEffectID, with task: Task<Void, Never>) {
        tasks[id]?.cancel()
        tasks[id] = task
    }

    func cancel(_ id: PlaybackEffectID) {
        tasks.removeValue(forKey: id)?.cancel()
    }

    func complete(_ id: PlaybackEffectID) {
        tasks[id] = nil
    }

    func cancelAccountScoped() {
        let ids = tasks.keys.filter(\.isAccountScoped)
        for id in ids { cancel(id) }
    }
}
