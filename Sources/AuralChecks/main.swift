import Foundation

let runner = CheckRunner()

runProtobufChecks(runner)
runShufflePolicyChecks(runner)
runPlaylistSortingChecks(runner)
runPlaybackSupportChecks(runner)
runParsingChecks(runner)
runPlaybackProjectionContractChecks(runner)
runPlaybackReducerChecks(runner)
runPlaybackCommandEffectSpikeChecks(runner)
runSessionLifetimeChecks(runner)

runner.report()
exit(runner.succeeded ? 0 : 1)
