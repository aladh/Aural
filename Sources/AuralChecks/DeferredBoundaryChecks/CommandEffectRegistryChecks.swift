import Foundation
@testable import AuralCore

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Work duration if cancellation fails. `awaitBounded` still fails the check well before 60s.
private let cancellationWorkNanoseconds: UInt64 = 50_000_000
private let cancellationWaitNanoseconds: UInt64 = 200_000_000

@MainActor
private final class SettlementPark {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isParked = false
    private(set) var didFinish = false

    func park() async {
        isParked = true
        await withCheckedContinuation { continuation = $0 }
        didFinish = true
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func awaitBounded(_ task: Task<Void, Never>) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await task.value
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: cancellationWaitNanoseconds)
            return false
        }
        let finished = await group.next() ?? false
        group.cancelAll()
        return finished
    }
}

@MainActor
func runCommandEffectRegistryChecks(_ runner: CheckRunner) async {
    await runner.suite("PlaybackEffectRegistry cancel in flight") {
        let effects = PlaybackEffectRegistry()
        let commandID = UUID()
        let finishedWithoutCancel = CancellationFlag()

        let superseded: Task<Void, Never> = Task {
            do {
                try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
            } catch {}
            if !Task.isCancelled {
                finishedWithoutCancel.mark()
            }
        }
        effects.replace(.command(commandID), with: superseded)
        effects.replace(.command(commandID), with: Task<Void, Never> {})
        runner.check("the superseded task ends without waiting out a long sleep", await awaitBounded(superseded))
        runner.check("replacing a command token cancels the superseded task", !finishedWithoutCancel.isSet)
    }

    await runner.suite("PlaybackEffectRegistry account-scoped invalidation") {
        let effects = PlaybackEffectRegistry()
        let commandSurvived = CancellationFlag()
        let lifecycleCancelled = CancellationFlag()

        let command: Task<Void, Never> = Task {
            do {
                try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
            } catch {}
            if !Task.isCancelled {
                commandSurvived.mark()
            }
        }
        let lifecycle: Task<Void, Never> = Task {
            await withTaskCancellationHandler {
                do {
                    try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
                } catch {}
            } onCancel: {
                lifecycleCancelled.mark()
            }
        }
        effects.replace(.command(UUID()), with: command)
        effects.replace(.lifecycle, with: lifecycle)

        effects.cancelAccountScoped()
        runner.check("account-scoped command cancellation is bounded", await awaitBounded(command))
        runner.check("account teardown cancels in-flight commands", !commandSurvived.isSet)
        runner.check(
            "process-lifetime listeners are not cancelled with account-scoped work",
            !lifecycleCancelled.isSet
        )

        effects.cancel(.lifecycle)
        runner.check("explicit lifecycle cancellation is bounded", await awaitBounded(lifecycle))
        runner.check("an explicit lifecycle cancel still stops the listener", lifecycleCancelled.isSet)
    }

    await runner.suite("PlaybackEffectRegistry complete does not drop a newer token") {
        let effects = PlaybackEffectRegistry()
        let commandID = UUID()
        let replacementCancelled = CancellationFlag()

        let supersededRegistration = PlaybackEffectRegistration()
        let superseded: Task<Void, Never> = Task {
            do {
                try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
            } catch {}
            effects.complete(.command(commandID), registration: supersededRegistration)
        }
        effects.replace(.command(commandID), with: superseded, registration: supersededRegistration)

        let replacementRegistration = PlaybackEffectRegistration()
        let replacement: Task<Void, Never> = Task {
            await withTaskCancellationHandler {
                do {
                    try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
                } catch {}
            } onCancel: {
                replacementCancelled.mark()
            }
        }
        effects.replace(.command(commandID), with: replacement, registration: replacementRegistration)
        runner.check("the superseded task ends without waiting out a long sleep", await awaitBounded(superseded))
        effects.cancel(.command(commandID))
        runner.check("the replacement token is still cancellable", await awaitBounded(replacement))
        runner.check("completing the superseded task did not drop the replacement", replacementCancelled.isSet)
    }

    await runner.suite("PlaybackEffectRegistry replace runs the previous onCancel") {
        let effects = PlaybackEffectRegistry()
        let commandID = UUID()
        let previousCancelled = CancellationFlag()
        effects.replace(.command(commandID), with: Task<Void, Never> {}, onCancel: {
            previousCancelled.mark()
        })
        effects.replace(.command(commandID), with: Task<Void, Never> {})
        runner.check("replacing a token runs the previous onCancel", previousCancelled.isSet)
    }

    await runner.suite("PlaybackEffectRegistry settlement follows the captured task") {
        runner.check(
            "a missing in-flight effect has no settlement handle",
            PlaybackEffectRegistry().settlement(of: .trackMetadata) == nil
        )

        let cancelled = PlaybackEffectRegistry()
        let cancelGate = SettlementPark()
        cancelled.replace(.trackMetadata, with: Task { await cancelGate.park() })
        runner.check("cancelled work parks before capture", await waitUntil { cancelGate.isParked })
        let cancelledHandle = cancelled.settlement(of: .trackMetadata)
        runner.notNil("cancelled work is registered before cancel", cancelledHandle)
        cancelled.cancel(.trackMetadata)
        runner.check("cancel drops the live settlement", cancelled.settlement(of: .trackMetadata) == nil)
        cancelGate.release()
        await cancelledHandle?.wait()
        runner.check("waiting on a captured cancelled task observes unwind after release", cancelGate.didFinish)

        let completed = PlaybackEffectRegistry()
        let completeGate = SettlementPark()
        let completeRegistration = PlaybackEffectRegistration()
        completed.replace(
            .positionRefresh,
            with: Task {
                await completeGate.park()
                completed.complete(.positionRefresh, registration: completeRegistration)
            },
            registration: completeRegistration
        )
        runner.check("completed work parks before capture", await waitUntil { completeGate.isParked })
        let completedHandle = completed.settlement(of: .positionRefresh)
        runner.notNil("completed work is registered before complete", completedHandle)
        completeGate.release()
        await completedHandle?.wait()
        runner.check("complete drops the live settlement", completed.settlement(of: .positionRefresh) == nil)
        runner.check("waiting on a captured completed task observes unwind after complete", completeGate.didFinish)

        let replaced = PlaybackEffectRegistry()
        let originalGate = SettlementPark()
        let replacementGate = SettlementPark()
        replaced.replace(.queueSnapshot, with: Task { await originalGate.park() })
        runner.check("original work parks before capture", await waitUntil { originalGate.isParked })
        let originalHandle = replaced.settlement(of: .queueSnapshot)
        runner.notNil("original work is registered before replace", originalHandle)
        replaced.replace(.queueSnapshot, with: Task { await replacementGate.park() })
        runner.check("replacement work parks after replace", await waitUntil { replacementGate.isParked })
        runner.notNil("replacement keeps a live settlement", replaced.settlement(of: .queueSnapshot))
        originalGate.release()
        await originalHandle?.wait()
        runner.check("the captured handle followed the original task", originalGate.didFinish)
        runner.check("the captured handle did not wait for the replacement", !replacementGate.didFinish)
        replacementGate.release()
        await replaced.settlement(of: .queueSnapshot)?.wait()
    }
}
