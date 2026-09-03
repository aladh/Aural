import Foundation

/// Wake-up for a writer that has armed a wait on a full ring.
///
/// Control and the pull side signal only while a wait is armed, covering the unlock-to-wait
/// window without leaving a generation for a later unrelated park. Timeouts use a monotonic
/// uptime deadline.
nonisolated final class PCMWriteSpace: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var signaled = false

    /// Marks that the caller will `wait`. Must run before releasing `bufferLock`.
    func arm() {
        condition.lock()
        waiting = true
        signaled = false
        condition.unlock()
    }

    /// Wakes an armed writer. No-op if no wait is in the unlock-to-wait or parked window.
    func signalIfArmed() {
        condition.lock()
        defer { condition.unlock() }
        guard waiting else { return }
        signaled = true
        condition.broadcast()
    }

    /// Returns `true` when an armed wait was signaled, `false` on timeout.
    /// `onWillBlock` runs while this lock is held, immediately before `condition.wait`.
    /// The callback must only signal a test handshake and return; it must not call
    /// `signalIfArmed`, or it would deadlock on this lock.
    @discardableResult
    func wait(timeoutMilliseconds: Int, onWillBlock: (() -> Void)? = nil) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if signaled {
            signaled = false
            waiting = false
            return true
        }
        let deadline =
            ProcessInfo.processInfo.systemUptime
            + Double(max(timeoutMilliseconds, 0)) / 1000
        onWillBlock?()
        while !signaled {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                waiting = false
                return false
            }
            _ = condition.wait(until: Date().addingTimeInterval(remaining))
        }
        signaled = false
        waiting = false
        return true
    }
}
