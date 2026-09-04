/// Replays deterministic event traces and records every intermediate state.
///
/// The harness deliberately knows nothing about playback. Domain scenarios can use it with a
/// pure reducer without constructing services, clocks, tasks, or UI state.
struct TraceHarness<State, Event> {
    let initialState: State
    let reduce: (inout State, Event) -> Void

    func replay(_ events: [Event]) -> [State] {
        var state = initialState
        return events.map { event in
            reduce(&state, event)
            return state
        }
    }
}
