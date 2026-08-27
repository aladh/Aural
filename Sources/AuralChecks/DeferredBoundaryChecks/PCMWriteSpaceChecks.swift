import Foundation
@testable import AuralCore

@MainActor
func runPCMWriteSpaceChecks(_ check: CheckRunner) {
    check.suite("PCM writer space wake") {
        let bypass = PCMWriteSpace()
        bypass.signal()
        check.check(
            "stop or flush before wait bypasses the parked writer",
            bypass.wait(timeoutMilliseconds: 0)
        )

        let idle = PCMWriteSpace()
        check.check(
            "a wait with no signal times out without spinning",
            !idle.wait(timeoutMilliseconds: 0)
        )

        let space = PCMWriteSpace()
        let finished = DispatchSemaphore(value: 0)
        let woke = PCMWriterWakeFlag()
        Thread.detachNewThread {
            woke.store(space.wait(timeoutMilliseconds: 5_000))
            finished.signal()
        }
        space.signal()
        check.check(
            "stop or flush wakes a waiting writer",
            finished.wait(timeout: .now() + .seconds(5)) == .success
        )
        check.check("the waiting writer observes the control signal", woke.load())
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
