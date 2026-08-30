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
            self.state = next
            self.state.options.repeatMode = .track
            let state = PlaybackState()
            state.transport = .playing
        }
        """
        check.equal(
            "an extra store-state assignment is reported",
            PlaybackStoreStateWriterContract.assignmentLines(in: illegal),
            [
                "state = PlaybackState()",
                "self.state = next",
            ]
        )
        check.equal(
            "direct member mutation is reported and local bindings are ignored",
            PlaybackStoreStateWriterContract.memberMutationLines(in: illegal),
            [
                "state.options.repeatMode = .track",
                "self.state.options.repeatMode = .track",
                "state.transport = .playing",
            ]
        )
        check.check(
            "qualified comparisons are not assignments",
            PlaybackStoreStateWriterContract.assignmentLines(in: "if self.state == next { }").isEmpty
        )
        check.check(
            "qualified reads are not member mutations",
            PlaybackStoreStateWriterContract.memberMutationLines(in: "let flags = self.state.options.repeatFlags").isEmpty
        )
        check.check(
            "underscore-prefixed identifiers are not store-state assignments",
            PlaybackStoreStateWriterContract.assignmentLines(in: "playback_state = next").isEmpty
        )
        check.check(
            "underscore-prefixed identifiers are not store-state member mutations",
            PlaybackStoreStateWriterContract.memberMutationLines(in: "playback_state.options.repeatMode = .track").isEmpty
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
            check.equal(
                "production PlaybackStore cannot call Date() for stamping",
                sources.flatMap(PlaybackStoreStateWriterContract.dateCallLines(in:)),
                []
            )
        }
    }

    check.suite("PlaybackStore Date() scan") {
        check.equal(
            "a Date() stamp is reported",
            PlaybackStoreStateWriterContract.dateCallLines(in: "receivedAt: Date = Date()"),
            ["receivedAt: Date = Date()"]
        )
        check.check(
            "Date type names without a call are ignored",
            PlaybackStoreStateWriterContract.dateCallLines(in: "receivedAt: Date? = nil").isEmpty
        )
        check.check(
            "commented Date() calls are ignored",
            PlaybackStoreStateWriterContract.dateCallLines(in: "// receivedAt: Date = Date()").isEmpty
        )
        check.check(
            "inline commented Date() calls are ignored",
            PlaybackStoreStateWriterContract.dateCallLines(in: "let receivedAt: Date // Date()").isEmpty
        )
        check.check(
            "block-commented Date() calls are ignored",
            PlaybackStoreStateWriterContract.dateCallLines(in: "/* Date() */ let receivedAt: Date").isEmpty
        )
        check.check(
            "Date() in a string literal is ignored",
            PlaybackStoreStateWriterContract.dateCallLines(in: #"let label = "Date()""#).isEmpty
        )
        check.equal(
            "a trailing comment does not hide a real Date() stamp",
            PlaybackStoreStateWriterContract.dateCallLines(in: "receivedAt: Date = Date() // stamp"),
            ["receivedAt: Date = Date() // stamp"]
        )
    }
}
