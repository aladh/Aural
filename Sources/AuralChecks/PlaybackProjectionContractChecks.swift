import Foundation

func runPlaybackProjectionContractChecks(_ check: CheckRunner) {
    check.suite("PlaybackStore projection contract") {
        let writable = """
            var phase: Phase {
                get { state.session }
                set { state.session = newValue }
            }
            """
        check.equal(
            "an explicit setter on a projection is reported",
            PlaybackStoreProjectionContract.explicitSetterLines(in: writable)
                .map { $0.trimmingCharacters(in: .whitespaces) },
            ["set { state.session = newValue }"]
        )
        check.check(
            "a parameterized setter is reported",
            PlaybackStoreProjectionContract.isExplicitSetterLine(
                "        set(newValue) { state.session = newValue }"
            )
        )

        let projectionsFile = """
            extension PlaybackStore {
                var phase: Phase { state.session }
                var trackURI: String { state.currentTrack?.uri ?? "" }
                func displayedPosition(at date: Date) -> TimeInterval { position }
            }
            """
        check.equal(
            "read-only projection files have no setter lines",
            PlaybackStoreProjectionContract.explicitSetterLines(in: projectionsFile),
            []
        )
        check.check(
            "set* methods are not setter accessors",
            !PlaybackStoreProjectionContract.isExplicitSetterLine(
                "    func setNotice(_ message: String?) {}"
            )
        )
        check.check(
            "didSet observers are not setter accessors",
            !PlaybackStoreProjectionContract.isExplicitSetterLine("        didSet { }")
        )
        check.check(
            "an inline get/set accessor is reported",
            PlaybackStoreProjectionContract.isExplicitSetterLine(
                "    var phase: Phase { get { state.session } set { state.session = newValue } }"
            )
        )
    }

    check.suite("CurrentTrackRow accessibility contract") {
        let expectedLabel =
            ".accessibilityLabel(\"Now playing \\(player.displayedTrackTitle) by \\(player.displayedArtistName)\")"
        let commentedBesideWrongLabel = """
            .accessibilityLabel("Now playing \\(player.trackTitle) by \\(player.artistName)") // \(expectedLabel)
            """
        check.check(
            "a commented expected label does not satisfy the check",
            !PlaybackStoreProjectionContract.uncommentedSource(commentedBesideWrongLabel)
                .contains(expectedLabel)
        )
        check.check(
            "an active expected label satisfies the check",
            PlaybackStoreProjectionContract.uncommentedSource("        \(expectedLabel)\n")
                .contains(expectedLabel)
        )

        check.noThrow("production CurrentTrackRow VoiceOver uses displayed projections") {
            let sources = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let panel = try String(
                contentsOf: sources.appending(path: "Aural/Views/SidePanelView.swift"),
                encoding: .utf8
            )
            let projections = PlaybackStoreProjectionContract.uncommentedSource(
                try String(
                    contentsOf: sources.appending(path: "Aural/Spotify/PlaybackStore+Projections.swift"),
                    encoding: .utf8
                )
            )
            check.check(
                "production VoiceOver label uses displayedTrackTitle and displayedArtistName",
                PlaybackStoreProjectionContract.uncommentedSource(panel).contains(expectedLabel)
            )
            check.check(
                "displayedTrackTitle prefers catalog then engine fallback",
                projections.contains(
                    "var displayedTrackTitle: String { catalogCurrentTrack?.title ?? trackTitle }"
                )
            )
            check.check(
                "displayedArtistName prefers catalog then engine fallback",
                projections.contains(
                    "var displayedArtistName: String { catalogCurrentTrack?.artist ?? artistName }"
                )
            )
        }
    }
}
