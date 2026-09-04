import Testing
import Foundation

@Test
func testPlaybackStoreStateWriterContract() {
    do {
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
        #expect(
            (PlaybackStoreStateWriterContract.assignmentLines(in: declaration))
                == ([
                    "private(set) var state = PlaybackState(accountEpoch: 1)",
                    "state = next",
                ]), "declaration and send commit are the only store-state assignments")
        #expect(
            (PlaybackStoreStateWriterContract.memberMutationLines(in: declaration)) == ([]),
            "the send commit path has no direct member mutation")

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
        #expect(
            (PlaybackStoreStateWriterContract.assignmentLines(in: illegal))
                == ([
                    "state = PlaybackState()",
                    "self.state = next",
                ]), "an extra store-state assignment is reported")
        #expect(
            (PlaybackStoreStateWriterContract.memberMutationLines(in: illegal))
                == ([
                    "state.options.repeatMode = .track",
                    "self.state.options.repeatMode = .track",
                    "state.transport = .playing",
                ]), "direct member mutation is reported and local bindings are ignored")
        #expect(
            (PlaybackStoreStateWriterContract.assignmentLines(in: "if self.state == next { }").isEmpty) == true,
            "qualified comparisons are not assignments")
        #expect(
            (PlaybackStoreStateWriterContract.memberMutationLines(in: "let flags = self.state.options.repeatFlags")
                .isEmpty) == true, "qualified reads are not member mutations")
        #expect(
            (PlaybackStoreStateWriterContract.assignmentLines(in: "playback_state = next").isEmpty) == true,
            "underscore-prefixed identifiers are not store-state assignments")
        #expect(
            (PlaybackStoreStateWriterContract.memberMutationLines(in: "playback_state.options.repeatMode = .track")
                .isEmpty) == true, "underscore-prefixed identifiers are not store-state member mutations")

        #expect(
            (PlaybackStoreStateWriterContract.assignmentLines(in: "if state == next { }").isEmpty) == true,
            "comparisons are not assignments")
        #expect(
            (PlaybackStoreStateWriterContract.memberMutationLines(in: "let flags = state.options.repeatFlags").isEmpty)
                == true, "reads are not member mutations")

        do {
            do {
                let sourcesDirectory = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appending(path: "Spotty/Spotify")
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
                #expect(
                    (productionAssignments)
                        == ([
                            "private(set) var state = PlaybackState(accountEpoch: 1)",
                            "state = next",
                        ]), "production PlaybackStore.state assignments are the declaration and send commit")
                #expect(
                    (productionMutations) == ([]), "production PlaybackStore files have no direct state member mutation"
                )

            } catch {
                Issue.record("\("production PlaybackStore sources are readable"): unexpected error \(error)")
            }
        }
    }
}
