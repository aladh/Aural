import Foundation

/// Operational failures for playback *commands* at the coordinator/store boundary.
///
/// Infrastructure codes stay in `PlaybackEngineResult`. Cancellation is not a case here:
/// command methods throw only `CancellationError`.
nonisolated enum PlaybackCommandFailure: Equatable, Sendable {
    /// The local engine declined the command without invalidating the session.
    case rejected
    /// The local session must be reinitialized before another local command can succeed.
    case reconnectRequired
    /// The remote Connect client rejected or failed the command.
    case remoteRejected
    /// The local engine returned an unrecognized result.
    case unavailable

    static func from(engineResult: PlaybackEngineResult) -> Result<Void, PlaybackCommandFailure> {
        if engineResult.isOK {
            return .success(())
        }
        if engineResult.requiresReconnect {
            return .failure(.reconnectRequired)
        }
        if engineResult.rawValue == -1 {
            return .failure(.rejected)
        }
        return .failure(.unavailable)
    }
}

/// User-facing command copy. Action strings stay specific ("Pause was rejected"); cases never
/// append engine codes or remote `localizedDescription` text.
nonisolated enum PlaybackCommandPresentation {
    static func noticeMessage(for failure: PlaybackCommandFailure, action: String) -> String {
        switch failure {
        case .rejected, .reconnectRequired, .remoteRejected, .unavailable:
            action
        }
    }
}
