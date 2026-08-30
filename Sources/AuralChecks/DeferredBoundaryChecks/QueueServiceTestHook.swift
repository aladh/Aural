import Foundation
@testable import AuralCore

/// Check-only scheduler that parks `QueueService` at the injected hook points.
/// Continuation storage, parking flags, and resume counters live here, not on
/// the shipping actor. `reset()` is check-owned; `QueueService.reset` does not
/// call it.
actor QueueServiceTestHook: QueueServiceHook {
    private var pendingConnectAccept = false
    private var connectAcceptGate: CheckedContinuation<Void, Never>?
    private var connectAcceptGateID: UInt64 = 0
    private var pendingCommittedReplacement = false
    private var committedReplacementGate: CheckedContinuation<Void, Never>?
    private var committedReplacementGateID: UInt64 = 0

    private(set) var resetCount = 0
    private(set) var acceptConnectEnterCount = 0
    private(set) var acceptConnectSuspendCount = 0
    private(set) var acceptConnectResumeCount = 0
    private(set) var committedReplacementEnterCount = 0
    private(set) var committedReplacementSuspendCount = 0
    private(set) var committedReplacementResumeCount = 0

    func parkNextConnectAccept() {
        pendingConnectAccept = true
    }

    func connectAcceptIsParked() -> Bool { connectAcceptGate != nil }

    func resumeConnectAccept() {
        guard let parked = connectAcceptGate else { return }
        connectAcceptGate = nil
        acceptConnectResumeCount += 1
        parked.resume()
    }

    func parkNextCommittedReplacement() {
        pendingCommittedReplacement = true
    }

    func committedReplacementIsParked() -> Bool { committedReplacementGate != nil }

    func resumeCommittedReplacement() {
        guard let parked = committedReplacementGate else { return }
        committedReplacementGate = nil
        committedReplacementResumeCount += 1
        parked.resume()
    }

    func beforeAcceptConnect() async {
        acceptConnectEnterCount += 1
        guard pendingConnectAccept else { return }
        pendingConnectAccept = false
        acceptConnectSuspendCount += 1
        connectAcceptGateID &+= 1
        let id = connectAcceptGateID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                connectAcceptGate = continuation
            }
        } onCancel: {
            Task { await self.resumeConnectAcceptIfCurrent(id) }
        }
    }

    func beforeRecordCommittedReplacement() async {
        committedReplacementEnterCount += 1
        guard pendingCommittedReplacement else { return }
        pendingCommittedReplacement = false
        committedReplacementSuspendCount += 1
        committedReplacementGateID &+= 1
        let id = committedReplacementGateID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                committedReplacementGate = continuation
            }
        } onCancel: {
            Task { await self.resumeCommittedReplacementIfCurrent(id) }
        }
    }

    func reset() async {
        resetCount += 1
        pendingConnectAccept = false
        resumeConnectAccept()
        pendingCommittedReplacement = false
        resumeCommittedReplacement()
    }

    private func resumeConnectAcceptIfCurrent(_ id: UInt64) {
        guard id == connectAcceptGateID else { return }
        resumeConnectAccept()
    }

    private func resumeCommittedReplacementIfCurrent(_ id: UInt64) {
        guard id == committedReplacementGateID else { return }
        resumeCommittedReplacement()
    }
}
