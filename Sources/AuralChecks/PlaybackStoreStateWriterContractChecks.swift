import Foundation

func runPlaybackStoreStateWriterContractChecks(_ check: CheckRunner) {
    check.suite("PlaybackStore.state writer contract") {
        let declaration = """
        @MainActor
        final class PlaybackStore {
            private(set) var state = PlaybackState(accountEpoch: 1)

            func send() -> Bool {
                var next = state
                if accepted {
                    state = next
                    return true
                }
                return false
            }
        }
        """
        check.equal(
            "declaration and send commit are the only store-state assignments",
            PlaybackStoreStateWriterContract.assignmentLines(in: declaration),
            [
                "private(set) var state = PlaybackState(accountEpoch: 1)",
                "state = next",
            ]
        )
        check.equal(
            "the send commit path has no direct member mutation",
            PlaybackStoreStateWriterContract.memberMutationLines(in: declaration),
            []
        )

        let illegal = """
        func apply() {
            state = PlaybackState()
            state.options.repeatMode = .track
            let state = PlaybackState()
            state.transport = .playing
        }
        """
        check.equal(
            "an extra store-state assignment is reported",
            PlaybackStoreStateWriterContract.assignmentLines(in: illegal),
            ["state = PlaybackState()"]
        )
        check.equal(
            "direct member mutation is reported and local bindings are ignored",
            PlaybackStoreStateWriterContract.memberMutationLines(in: illegal),
            [
                "state.options.repeatMode = .track",
                "state.transport = .playing",
            ]
        )

        check.check(
            "comparisons are not assignments",
            PlaybackStoreStateWriterContract.assignmentLines(in: "if state == next { }").isEmpty
        )
        check.check(
            "reads are not member mutations",
            PlaybackStoreStateWriterContract.memberMutationLines(in: "let flags = state.options.repeatFlags").isEmpty
        )

        check.noThrow("production PlaybackStore sources are readable") {
            let sourcesDirectory = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Aural/Spotify")
            let storeFiles = [
                "PlaybackStore.swift",
                "PlaybackStore+Commands.swift",
                "PlaybackStore+EngineEvents.swift",
                "PlaybackStore+History.swift",
                "PlaybackStore+Projections.swift",
                "PlaybackStore+Queue.swift",
                "PlaybackStore+Session.swift",
                "PlaybackStore+Transport.swift",
            ]
            let sources = try storeFiles.map { file in
                try String(contentsOf: sourcesDirectory.appending(path: file), encoding: .utf8)
            }
            let productionAssignments = sources.flatMap(PlaybackStoreStateWriterContract.assignmentLines(in:))
            let productionMutations = sources.flatMap(PlaybackStoreStateWriterContract.memberMutationLines(in:))
            check.equal(
                "production PlaybackStore.state assignments are the declaration and send commit",
                productionAssignments,
                [
                    "private(set) var state = PlaybackState(accountEpoch: 1)",
                    "state = next",
                ]
            )
            check.equal(
                "production PlaybackStore files have no direct state member mutation",
                productionMutations,
                []
            )
        }
    }
}
