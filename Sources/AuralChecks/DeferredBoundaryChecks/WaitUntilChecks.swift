@MainActor
func runWaitUntilChecks(_ check: CheckRunner) async {
    await check.suite("waitUntil contract") {
        let immediate = await waitUntil { true }
        check.check("already-true condition succeeds", immediate)

        let expired = await waitUntil(timeout: .zero) { true }
        check.check("zero timeout is already expired", !expired)

        let task = Task { @MainActor in
            await waitUntil { true }
        }
        task.cancel()
        let cancelled = await task.value
        check.check("cancelled wait returns false promptly", !cancelled)
    }
}
