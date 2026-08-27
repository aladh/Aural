import Foundation
@testable import AuralCore

@MainActor
func runPCMWriteSpaceChecks(_ check: CheckRunner) {
    check.suite("PCM writer space wake") {
        let stale = PCMWriteSpace()
        stale.signalIfArmed()
        stale.arm()
        check.check(
            "a control signal with no armed writer is not consumed by a later wait",
            !stale.wait(timeoutMilliseconds: 0)
        )

        let idle = PCMWriteSpace()
        idle.arm()
        check.check(
            "a wait with no signal times out without spinning",
            !idle.wait(timeoutMilliseconds: 0)
        )

        let bypass = PCMWriteSpace()
        bypass.arm()
        bypass.signalIfArmed()
        check.check(
            "stop or flush in the unlock-to-wait window wakes the writer",
            bypass.wait(timeoutMilliseconds: 0)
        )

        let space = PCMWriteSpace()
        let parked = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let woke = PCMWriterWakeFlag()
        Thread.detachNewThread {
            space.arm()
            woke.store(
                space.wait(timeoutMilliseconds: 5_000, onWillBlock: { parked.signal() })
            )
            finished.signal()
        }
        check.check(
            "the writer handshake arrives before the park",
            parked.wait(timeout: .now() + .seconds(5)) == .success
        )
        space.signalIfArmed()
        check.check(
            "stop or flush wakes a genuinely parked writer",
            finished.wait(timeout: .now() + .seconds(5)) == .success
        )
        check.check("the parked writer observes the control signal", woke.load())
    }
}

private final class PCMWriterWakeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func store(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
