@MainActor
private final class WaitUntilCheckProbe {
    var entered = false
}

@MainActor
func runWaitUntilChecks(_ check: CheckRunner) async {
    await check.suite("waitUntil contract") {
        let immediate = await waitUntil { true }
        check.check("already-true condition succeeds", immediate)

        let expired = await waitUntil(timeout: .zero) { true }
        check.check("zero timeout is already expired", !expired)

        let cancelledBeforeStart = Task { @MainActor in
            await waitUntil { true }
        }
        cancelledBeforeStart.cancel()
        check.check(
            "cancelled wait returns false before polling",
            await cancelledBeforeStart.value == false
        )

        let probe = WaitUntilCheckProbe()
        let cancelledDuringPoll = Task { @MainActor in
            await waitUntil {
                probe.entered = true
                return false
            }
        }
        while !probe.entered {
            await Task.yield()
        }
        cancelledDuringPoll.cancel()
        check.check(
            "cancelled wait returns false during polling",
            await cancelledDuringPoll.value == false
        )
    }
}
