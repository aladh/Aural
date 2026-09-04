/// Test-only cooperative wait for concrete boundary checks.
/// Polls on the MainActor with `Task.yield` until `condition` is true, the task is
/// cancelled, or `timeout` elapses. The default deadline is two seconds. A true
/// predicate is accepted only if cancellation and the deadline are still valid
/// after it returns.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    if Task.isCancelled { return false }
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if Task.isCancelled { return false }
        let matched = await condition()
        if Task.isCancelled { return false }
        if clock.now >= deadline { return false }
        if matched { return true }
        await Task.yield()
    }
    return false
}
