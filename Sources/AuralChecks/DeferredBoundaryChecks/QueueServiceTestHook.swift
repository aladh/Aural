import Foundation
@testable import AuralCore

/// Check-only scheduler that parks `QueueService` at the injected hook points.
/// Pending flags, continuations, and generation IDs live here, not on the
/// shipping actor.
actor QueueServiceTestHook: QueueServiceHook {
    private var pendingConnectAccept = false
    private var connectAcceptGate: CheckedContinuation<Void, Never>?
    private var connectAcceptGateID: UInt64 = 0
    private var pendingCommittedReplacement = false
    private var committedReplacementGate: CheckedContinuation<Void, Never>?
    private var committedReplacementGateID: UInt64 = 0

    func parkNextConnectAccept() {
        pendingConnectAccept = true
    }

    func connectAcceptIsParked() -> Bool { connectAcceptGate != nil }

    func resumeConnectAccept() {
        guard let parked = connectAcceptGate else { return }
        connectAcceptGate = nil
        parked.resume()
    }

    func parkNextCommittedReplacement() {
        pendingCommittedReplacement = true
    }

    func committedReplacementIsParked() -> Bool { committedReplacementGate != nil }

    func resumeCommittedReplacement() {
        guard let parked = committedReplacementGate else { return }
        committedReplacementGate = nil
        parked.resume()
    }

    func beforeAcceptConnect() async {
        guard pendingConnectAccept else { return }
        pendingConnectAccept = false
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
        guard pendingCommittedReplacement else { return }
        pendingCommittedReplacement = false
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

    private func resumeConnectAcceptIfCurrent(_ id: UInt64) {
        guard id == connectAcceptGateID else { return }
        resumeConnectAccept()
    }

    private func resumeCommittedReplacementIfCurrent(_ id: UInt64) {
        guard id == committedReplacementGateID else { return }
        resumeCommittedReplacement()
    }
}
