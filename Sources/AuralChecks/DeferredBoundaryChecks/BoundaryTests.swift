import AuralCheckSelection
import Foundation

private struct RegisteredCheckSuite {
    let name: String
    let run: @MainActor (CheckRunner) async -> Void
}

@MainActor
@main
enum BoundaryChecksMain {
    static var suiteNames: [String] { registeredSuites().map(\.name) }

    private static func registeredSuites() -> [RegisteredCheckSuite] {
        [
            RegisteredCheckSuite(name: "auth-flow") { runAuthFlowChecks($0) },
            RegisteredCheckSuite(name: "keymaster-persistence") { runKeymasterPersistenceChecks($0) },
            RegisteredCheckSuite(name: "keymaster-persistence-source-contract") {
                runKeymasterPersistenceSourceContractChecks($0)
            },
            RegisteredCheckSuite(name: "pagination") { runPaginationChecks($0) },
            RegisteredCheckSuite(name: "playback-panel") { runPlaybackPanelChecks($0) },
            RegisteredCheckSuite(name: "loopback-parsing") { runLoopbackParsingChecks($0) },
            RegisteredCheckSuite(name: "loopback-server") { await runLoopbackServerChecks($0) },
            RegisteredCheckSuite(name: "auth-cookie-cleanup") { await runAuthCookieCleanupChecks($0) },
            RegisteredCheckSuite(name: "keymaster-session-persistence") {
                await runKeymasterSessionPersistenceChecks($0)
            },
            RegisteredCheckSuite(name: "auth-credential-retry") { await runAuthCredentialRetryChecks($0) },
            RegisteredCheckSuite(name: "transport-retry") { await runTransportRetryChecks($0) },
            RegisteredCheckSuite(name: "connect-metadata-transport") { await runConnectMetadataTransportChecks($0) },
            RegisteredCheckSuite(name: "uri") { runURIChecks($0) },
            RegisteredCheckSuite(name: "formatting") { runFormattingChecks($0) },
            RegisteredCheckSuite(name: "track-attribute") { runTrackAttributeChecks($0) },
            RegisteredCheckSuite(name: "media-selection") { runMediaSelectionChecks($0) },
            RegisteredCheckSuite(name: "resume-load-sequence") { runResumeLoadSequenceChecks($0) },
            RegisteredCheckSuite(name: "audio-key-cache") { runAudioKeyCacheChecks($0) },
            RegisteredCheckSuite(name: "fixture-contract") { runFixtureContractChecks($0) },
            RegisteredCheckSuite(name: "engine-payload-contract") { runEnginePayloadContractChecks($0) },
            RegisteredCheckSuite(name: "pcm-write-space") { runPCMWriteSpaceChecks($0) },
            RegisteredCheckSuite(name: "engine-event-fanout") { runEngineEventFanoutChecks($0) },
            RegisteredCheckSuite(name: "audio-renderer-ownership") {
                runAudioRendererOwnershipChecks($0)
            },
            RegisteredCheckSuite(name: "privacy-sanitization") { await runPrivacySanitizationChecks($0) },
            RegisteredCheckSuite(name: "pagination-walk") { await runPaginationWalkChecks($0) },
            RegisteredCheckSuite(name: "workflow") { await runWorkflowChecks($0) },
            RegisteredCheckSuite(name: "home-library-store") { await runHomeLibraryStoreChecks($0) },
            RegisteredCheckSuite(name: "search-store") { await runSearchStoreChecks($0) },
            RegisteredCheckSuite(name: "media-detail-store") { await runMediaDetailStoreChecks($0) },
            RegisteredCheckSuite(name: "account-epoch-ownership") { await runAccountEpochOwnershipChecks($0) },
            RegisteredCheckSuite(name: "command-effect-registry") { await runCommandEffectRegistryChecks($0) },
            RegisteredCheckSuite(name: "playback-command-failure") { await runPlaybackCommandFailureChecks($0) },
            RegisteredCheckSuite(name: "playback-command-lifecycle-parity") {
                await runPlaybackCommandLifecycleParityChecks($0)
            },
            RegisteredCheckSuite(name: "repeat-transition") { await runRepeatTransitionChecks($0) },
            RegisteredCheckSuite(name: "playback-event-outcome") { await runPlaybackEventOutcomeChecks($0) },
            RegisteredCheckSuite(name: "playlist-mutation") { await runPlaylistMutationChecks($0) },
            RegisteredCheckSuite(name: "queue-management") { await runQueueManagementChecks($0) },
            RegisteredCheckSuite(name: "transient-feedback") { await runTransientFeedbackChecks($0) },
            RegisteredCheckSuite(name: "visual-style-contract") { runVisualStyleContractChecks($0) },
            RegisteredCheckSuite(name: "visual-contrast") { runVisualContrastChecks($0) },
            RegisteredCheckSuite(name: "wait-until") { await runWaitUntilChecks($0) },
            RegisteredCheckSuite(name: "check-suite-selection") { runner in
                runCheckSuiteSelectionChecks(runner, catalog: BoundaryChecksMain.suiteNames)
            },
        ]
    }

    static func main() async {
        let suites = registeredSuites()
        let catalog = suites.map(\.name)
        let launch = CheckSuiteLaunch.interpret(
            arguments: Array(CommandLine.arguments.dropFirst()),
            catalog: catalog,
            executableName: "AuralBoundaryChecks",
            printOutput: { print($0) },
            printError: writeCheckSelectionError
        )
        guard let namesToRun = launch.suiteNames else {
            exit(launch.failed ? 2 : 0)
        }

        let runner = CheckRunner()
        let runs = Dictionary(uniqueKeysWithValues: suites.map { ($0.name, $0.run) })
        for name in namesToRun {
            guard let run = runs[name] else {
                writeCheckSelectionError("Check suite \(name) was selected but not registered.")
                exit(2)
            }
            await run(runner)
        }
        if !runner.succeeded {
            print(runner.failures.joined(separator: "\n"))
            exit(1)
        }
        print("All \(runner.checksRun) concrete boundary checks passed.")
    }
}
