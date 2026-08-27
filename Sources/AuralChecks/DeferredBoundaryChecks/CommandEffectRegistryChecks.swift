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

@MainActor
func runCommandEffectRegistryChecks(_ runner: CheckRunner) async {
    await runner.suite("PlaybackEffectRegistry cancel in flight") {
        let effects = PlaybackEffectRegistry()
        let commandID = UUID()
        let finishedWithoutCancel = CancellationFlag()

        let superseded: Task<Void, Never> = Task {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {}
            if !Task.isCancelled {
                finishedWithoutCancel.mark()
            }
        }
        effects.replace(.command(commandID), with: superseded)
        effects.replace(.command(commandID), with: Task<Void, Never> {})
        await superseded.value
        runner.check("replacing a command token cancels the superseded task", !finishedWithoutCancel.isSet)
    }

    await runner.suite("PlaybackEffectRegistry account-scoped invalidation") {
        let effects = PlaybackEffectRegistry()
        let commandSurvived = CancellationFlag()
        let lifecycleCancelled = CancellationFlag()

        let command: Task<Void, Never> = Task {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {}
            if !Task.isCancelled {
                commandSurvived.mark()
            }
        }
        // Explicit Task<Void, Never>: `try? await` as the closure result infers
        // Task<Void?, Never>, which replace(_:) does not accept.
        let lifecycle: Task<Void, Never> = Task {
            await withTaskCancellationHandler {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {}
            } onCancel: {
                lifecycleCancelled.mark()
            }
        }
        effects.replace(.command(UUID()), with: command)
        effects.replace(.lifecycle, with: lifecycle)

        effects.cancelAccountScoped()
        await command.value
        runner.check("account teardown cancels in-flight commands", !commandSurvived.isSet)
        runner.check(
            "process-lifetime listeners are not cancelled with account-scoped work",
            !lifecycleCancelled.isSet
        )

        effects.cancel(.lifecycle)
        await lifecycle.value
        runner.check("an explicit lifecycle cancel still stops the listener", lifecycleCancelled.isSet)
    }
}
