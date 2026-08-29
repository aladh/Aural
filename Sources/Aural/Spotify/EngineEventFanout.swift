import Foundation

/// Process-local fan-out for typed engine control events.
///
/// Sequence assignment and delivery are one owner. Concurrent callback threads (player pump,
/// cluster listener, devices) may otherwise assign sequence *N*, unlock, pause, and yield after
/// *N+1* has already been delivered. `PlaybackStore.receive` would then drop *N*.
///
/// `AsyncStream.Continuation.yield` can resume a waiting consumer on this thread. That consumer
/// may cancel, which runs `onTermination` and reacquires this lock, or it may subscribe / emit
/// again. Holding the lock across `yield`, `finish`, or `onStart` work that can synchronously
/// re-enter therefore deadlocks a non-recursive `NSLock`. The claimant drain unlocks before every
/// yield; other emitters only enqueue. Mixed-kind `bufferingNewest(64)` eviction is unchanged.
nonisolated final class EngineEventFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RustPlaybackEventEnvelope>.Continuation] = [:]
    private var pending: [RustPlaybackEventEnvelope] = []
    private var sequence: UInt64 = 0
    private var delivering = false

    /// `onStart` runs after the continuation is installed and the lock is released, matching the
    /// engine's "subscribe before synchronous registration" rule. `onTermination` runs after the
    /// continuation is removed, still without the lock held.
    func events(
        onStart: (@Sendable () -> Void)? = nil,
        onTermination: (@Sendable () -> Void)? = nil
    ) -> AsyncStream<RustPlaybackEventEnvelope> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
                onTermination?()
            }
            onStart?()
        }
    }

    /// `afterPrepare` runs after this envelope's sequence is assigned and it is queued, and before
    /// this thread yields or returns. Tests use it to force A-before-B assignment and B-before-A
    /// scheduling. It must not wait on this drain completing if it also calls `emit`.
    func emit(_ event: RustPlaybackEvent, afterPrepare: (@Sendable () -> Void)? = nil) {
        lock.lock()
        sequence &+= 1
        pending.append(
            RustPlaybackEventEnvelope(
                sequence: sequence,
                receivedAt: Date(),
                event: event
            )
        )
        let claimedDelivery = !delivering
        if claimedDelivery {
            delivering = true
        }
        lock.unlock()

        afterPrepare?()

        guard claimedDelivery else { return }
        deliverPending()
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }

    private func deliverPending() {
        while true {
            lock.lock()
            if pending.isEmpty {
                delivering = false
                lock.unlock()
                return
            }
            let envelope = pending.removeFirst()
            let targets = Array(continuations.values)
            lock.unlock()
            for continuation in targets {
                continuation.yield(envelope)
            }
        }
    }
}
