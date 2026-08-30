import Foundation

@MainActor
@main
enum BoundaryChecksMain {
    static func main() async {
        let runner = CheckRunner()

        runAuthFlowChecks(runner)
        runKeymasterPersistenceChecks(runner)
        runKeymasterPersistenceSourceContractChecks(runner)
        runPaginationChecks(runner)
        runPlaybackPanelChecks(runner)
        runLoopbackParsingChecks(runner)
        await runLoopbackServerChecks(runner)
        await runAuthCookieCleanupChecks(runner)
        await runKeymasterSessionPersistenceChecks(runner)
        await runAuthCredentialRetryChecks(runner)
        await runTransportRetryChecks(runner)
        await runConnectMetadataTransportChecks(runner)
        runURIChecks(runner)
        runFormattingChecks(runner)
        runTrackAttributeChecks(runner)
        runFixtureContractChecks(runner)
        runEnginePayloadContractChecks(runner)
        runPCMWriteSpaceChecks(runner)
        runEngineEventFanoutChecks(runner)
        await runPrivacySanitizationChecks(runner)
        await runPaginationWalkChecks(runner)
        await runWorkflowChecks(runner)
        await runAccountEpochOwnershipChecks(runner)
        await runCommandEffectRegistryChecks(runner)
        await runPlaybackCommandFailureChecks(runner)
        await runPlaybackCommandLifecycleParityChecks(runner)
        await runRepeatTransitionChecks(runner)
        await runPlaybackEventOutcomeChecks(runner)
        await runPlaylistMutationChecks(runner)
        await runQueueManagementChecks(runner)
        await runTransientFeedbackChecks(runner)

        if !runner.succeeded {
            print(runner.failures.joined(separator: "\n"))
            exit(1)
        }
        print("All \(runner.checksRun) concrete boundary checks passed.")
    }
}
