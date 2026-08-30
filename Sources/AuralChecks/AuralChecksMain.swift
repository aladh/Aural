import Foundation

@main
enum AuralChecksMain {
    static func main() async {
        let runner = CheckRunner()

        runProtobufChecks(runner)
        runShufflePolicyChecks(runner)
        runTrackTableDisplayCacheChecks(runner)
        runPlaybackSupportChecks(runner)
        runParsingChecks(runner)
        await runPaginationCollectChecks(runner)
        runSpotifyTransientRetryChecks(runner)
        runPlaybackProjectionContractChecks(runner)
        runPlaybackStoreStateWriterContractChecks(runner)
        runPlaybackReducerChecks(runner)
        runPlaybackCommandPresentationChecks(runner)
        runPlaybackCommandLifecycleChecks(runner)
        runPlaybackCommandEffectSpikeChecks(runner)
        runSessionLifetimeChecks(runner)
        runPlaylistEditabilityChecks(runner)
        runQueueMutationChecks(runner)

        runner.report()
        exit(runner.succeeded ? 0 : 1)
    }
}
