import Foundation

let runner = CheckRunner()

runProtobufChecks(runner)
runShufflePolicyChecks(runner)
runPlaylistSortingChecks(runner)
runPlaybackSupportChecks(runner)
runParsingChecks(runner)
runPlaybackProjectionContractChecks(runner)
runPlaybackReducerChecks(runner)
runPlaybackCommandPresentationChecks(runner)
runPlaybackCommandEffectSpikeChecks(runner)
runSessionLifetimeChecks(runner)
runPlaylistEditabilityChecks(runner)
runQueueMutationChecks(runner)

runner.report()
exit(runner.succeeded ? 0 : 1)
