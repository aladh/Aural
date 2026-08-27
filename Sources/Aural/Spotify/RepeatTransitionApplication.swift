import AuralDomain

/// Repeat-specific application of `RepeatTransitionPlan` for the local FFI and
/// remote Connect paths. Not a generic transaction or two-phase command type.
enum RepeatTransitionApplication {
    /// Applies forward mutations in plan order. A first-step failure returns that
    /// result with no compensation. After a later step fails, compensation runs
    /// best-effort (its results are ignored) and the failed step's result is returned.
    static func apply(
        _ plan: RepeatTransitionPlan,
        setContext: (Bool) -> PlaybackEngineResult,
        setTrack: (Bool) -> PlaybackEngineResult
    ) -> PlaybackEngineResult {
        func apply(_ mutation: RepeatFlagMutation) -> PlaybackEngineResult {
            switch mutation.flag {
            case .context: setContext(mutation.enabled)
            case .track: setTrack(mutation.enabled)
            }
        }

        for (index, mutation) in plan.mutations.enumerated() {
            let result = apply(mutation)
            guard result.isOK else {
                if index > 0 {
                    for item in plan.compensation {
                        _ = apply(item)
                    }
                }
                return result
            }
        }
        return .ok
    }

    /// Same skip/order/compensation rules for the throwing Connect client.
    /// Compensation uses `try?` so a compensation failure cannot be reported as success.
    static func applyRemote(
        _ plan: RepeatTransitionPlan,
        send: (RepeatFlagMutation) async throws -> Void
    ) async throws {
        for (index, mutation) in plan.mutations.enumerated() {
            do {
                try await send(mutation)
            } catch {
                if index > 0 {
                    for item in plan.compensation {
                        try? await send(item)
                    }
                }
                throw error
            }
        }
    }
}
