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

        let superseded: Task<Void, Never> = Task {
            do {
                try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
            } catch {}
            effects.complete(.command(commandID))
        }
        effects.replace(.command(commandID), with: superseded)

        let replacement: Task<Void, Never> = Task {
            await withTaskCancellationHandler {
                do {
                    try await Task.sleep(nanoseconds: cancellationWorkNanoseconds)
                } catch {}
            } onCancel: {
                replacementCancelled.mark()
            }
        }
        effects.replace(.command(commandID), with: replacement)
        runner.check("the superseded task ends without waiting out a long sleep", await awaitBounded(superseded))
        effects.cancel(.command(commandID))
        runner.check("the replacement token is still cancellable", await awaitBounded(replacement))
        runner.check("completing the superseded task did not drop the replacement", replacementCancelled.isSet)
    }
}
