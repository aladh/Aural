import AuralCheckSelection
import Foundation

private struct RegisteredCheckSuite {
    let name: String
    let run: (CheckRunner) async -> Void
}

@main
enum AuralChecksMain {
    static var suiteNames: [String] { registeredSuites().map(\.name) }

    private static func registeredSuites() -> [RegisteredCheckSuite] {
        [
            RegisteredCheckSuite(name: "protobuf") { runProtobufChecks($0) },
            RegisteredCheckSuite(name: "shuffle-policy") { runShufflePolicyChecks($0) },
            RegisteredCheckSuite(name: "track-table-display-cache") { runTrackTableDisplayCacheChecks($0) },
            RegisteredCheckSuite(name: "playback-support") { runPlaybackSupportChecks($0) },
            RegisteredCheckSuite(name: "parsing") { runParsingChecks($0) },
            RegisteredCheckSuite(name: "pagination-collect") { await runPaginationCollectChecks($0) },
            RegisteredCheckSuite(name: "spotify-transient-retry") { runSpotifyTransientRetryChecks($0) },
            RegisteredCheckSuite(name: "playback-projection-contract") { runPlaybackProjectionContractChecks($0) },
            RegisteredCheckSuite(name: "playback-store-state-writer-contract") {
                runPlaybackStoreStateWriterContractChecks($0)
            },
            RegisteredCheckSuite(name: "playback-reducer") { runPlaybackReducerChecks($0) },
            RegisteredCheckSuite(name: "playback-command-presentation") { runPlaybackCommandPresentationChecks($0) },
            RegisteredCheckSuite(name: "playback-command-lifecycle") { runPlaybackCommandLifecycleChecks($0) },
            RegisteredCheckSuite(name: "playback-command-effect-spike") { runPlaybackCommandEffectSpikeChecks($0) },
            RegisteredCheckSuite(name: "session-lifetime") { runSessionLifetimeChecks($0) },
            RegisteredCheckSuite(name: "playlist-editability") { runPlaylistEditabilityChecks($0) },
            RegisteredCheckSuite(name: "queue-mutation") { runQueueMutationChecks($0) },
            RegisteredCheckSuite(name: "connect-device-projection") { runConnectDeviceProjectionChecks($0) },
            RegisteredCheckSuite(name: "connection-snapshot-projection") {
                runConnectionSnapshotProjectionChecks($0)
            },
            RegisteredCheckSuite(name: "playback-snapshot-projection") {
                runPlaybackSnapshotProjectionChecks($0)
            },
            RegisteredCheckSuite(name: "resume-load-plan") { runResumeLoadPlanChecks($0) },
            RegisteredCheckSuite(name: "ogg-page") { runOggPageChecks($0) },
            RegisteredCheckSuite(name: "check-suite-selection") { runner in
                runCheckSuiteSelectionChecks(runner, catalog: AuralChecksMain.suiteNames)
            },
        ]
    }

    static func main() async {
        let suites = registeredSuites()
        let catalog = suites.map(\.name)
        let launch = CheckSuiteLaunch.interpret(
            arguments: Array(CommandLine.arguments.dropFirst()),
            catalog: catalog,
            executableName: "AuralChecks",
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

        runner.report()
        exit(runner.succeeded ? 0 : 1)
    }
}
