import Foundation
@testable import AuralCore

/// Lock-protected continuation so cancellation can resume without hopping back
/// onto an actor that is already waiting in that continuation.
private final class ParkedGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var generation: UInt64 = 0

    func parkNext() {
        lock.lock()
        pending = true
        lock.unlock()
    }

    func isParked() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func resume() {
        lock.lock()
        let parked = continuation
        continuation = nil
        lock.unlock()
        parked?.resume()
    }

    func waitIfPending() async {
        lock.lock()
        guard pending else {
            lock.unlock()
            return
        }
        pending = false
        generation &+= 1
        let id = generation
        lock.unlock()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if Task.isCancelled || generation != id {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let parked: CheckedContinuation<Void, Never>?
            if generation == id {
                parked = continuation
                continuation = nil
            } else {
                parked = nil
            }
            lock.unlock()
            parked?.resume()
        }
    }
}

/// Check-only scheduler that parks `QueueService` at the injected hook points.
actor QueueServiceTestHook: QueueServiceHook {
    private let accept = ParkedGate()
    private let replacement = ParkedGate()

    func parkNextConnectAccept() { accept.parkNext() }
    func connectAcceptIsParked() -> Bool { accept.isParked() }
    func resumeConnectAccept() { accept.resume() }

    func parkNextCommittedReplacement() { replacement.parkNext() }
    func committedReplacementIsParked() -> Bool { replacement.isParked() }
    func resumeCommittedReplacement() { replacement.resume() }

    func beforeAcceptConnect() async { await accept.waitIfPending() }
    func beforeRecordCommittedReplacement() async { await replacement.waitIfPending() }
}
