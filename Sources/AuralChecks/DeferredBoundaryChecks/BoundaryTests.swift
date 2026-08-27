import Foundation

@MainActor
@main
enum BoundaryChecksMain {
    static func main() async {
        let runner = CheckRunner()

        runAuthFlowChecks(runner)
        runPaginationChecks(runner)
        runPlaybackPanelChecks(runner)
        runLoopbackParsingChecks(runner)
        await runLoopbackServerChecks(runner)
        await runAuthCookieCleanupChecks(runner)
        runURIChecks(runner)
        runFormattingChecks(runner)
        runPlaylistSortingChecks(runner)
        runTrackAttributeChecks(runner)
        runFixtureContractChecks(runner)
        runPCMWriteSpaceChecks(runner)
        await runPrivacySanitizationChecks(runner)
        await runWorkflowChecks(runner)
        await runCommandEffectRegistryChecks(runner)
        await runPlaybackCommandFailureChecks(runner)
        await runPlaybackEventOutcomeChecks(runner)
        await runPlaylistMutationChecks(runner)
        await runTransientFeedbackChecks(runner)

        if !runner.succeeded {
            print(runner.failures.joined(separator: "\n"))
            exit(1)
        }
        print("All \(runner.checksRun) concrete boundary checks passed.")
    }
}
