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
        check.equal(
            "comment and string near-misses do not produce setter lines",
            PlaybackStoreProjectionContract.explicitSetterLines(
                in: #"""
                    // set { state.session = newValue }
                    var phase: Phase { state.session } // set { }
                    let sample = "set { }"
                    /* set { state.session = newValue } */
                    /*
                    set { state.session = newValue }
                    */
                    let documented = """
                    set { state.session = newValue }
                    """
                    """#
            ),
            []
        )
        check.equal(
            "an accessor after a multiline string is still reported",
            PlaybackStoreProjectionContract.explicitSetterLines(
                in: #"""
                    let documented = """
                    set { ignored }
                    """
                        set { state.session = newValue }
                    """#
            ).map { $0.trimmingCharacters(in: .whitespaces) },
            ["set { state.session = newValue }"]
        )

        check.noThrow("production PlaybackStore projections are readable") {
            let projectionsURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Aural/Spotify/PlaybackStore+Projections.swift")
            let source = try String(contentsOf: projectionsURL, encoding: .utf8)
            check.equal(
                "production PlaybackStore projections have no explicit setters",
                PlaybackStoreProjectionContract.explicitSetterLines(in: source),
                []
            )
        }
    }

    check.suite("CurrentTrackRow accessibility contract") {
        let expectedLabel =
            ".accessibilityLabel(\"Now playing \\(player.displayedTrackTitle) by \\(player.displayedArtistName)\")"
        let expectedTitle =
            "var displayedTrackTitle: String { catalogCurrentTrack?.title ?? trackTitle }"
        let expectedArtist =
            "var displayedArtistName: String { catalogCurrentTrack?.artist ?? artistName }"

        check.check(
            "a line-commented expected label does not satisfy the check",
            !PlaybackStoreProjectionContract.containsUncommented(
                ".accessibilityLabel(\"Now playing \\(player.trackTitle) by \\(player.artistName)\") // \(expectedLabel)",
                expectedLabel
            )
        )
        check.check(
            "a block-commented expected label does not satisfy the check",
            !PlaybackStoreProjectionContract.containsUncommented(
                ".accessibilityLabel(\"Now playing \\(player.trackTitle) by \\(player.artistName)\")\n/* \(expectedLabel) */",
                expectedLabel
            )
        )
        check.check(
            "an active expected label satisfies the check",
            PlaybackStoreProjectionContract.containsUncommented("        \(expectedLabel)\n", expectedLabel)
        )
        check.check(
            "a quoted block-comment marker does not hide an active expected label",
            PlaybackStoreProjectionContract.containsUncommented(
                "let marker = \"/*\"\n        \(expectedLabel)\n",
                expectedLabel
            )
        )
        check.check(
            "a quoted URL does not hide an active expected label",
            PlaybackStoreProjectionContract.containsUncommented(
                "let artwork = \"https://example.invalid/track\"\n        \(expectedLabel)\n",
                expectedLabel
            )
        )
        check.check(
            "a line-commented displayedTrackTitle does not satisfy the check",
            !PlaybackStoreProjectionContract.containsUncommented(
                "var displayedTrackTitle: String { trackTitle } // \(expectedTitle)",
                expectedTitle
            )
        )
        check.check(
            "a block-commented displayedTrackTitle does not satisfy the check",
            !PlaybackStoreProjectionContract.containsUncommented(
                "var displayedTrackTitle: String { trackTitle }\n/* \(expectedTitle) */",
                expectedTitle
            )
        )
        check.check(
            "a line-commented displayedArtistName does not satisfy the check",
            !PlaybackStoreProjectionContract.containsUncommented(
                "var displayedArtistName: String { artistName } // \(expectedArtist)",
                expectedArtist
            )
        )
        check.check(
            "a block-commented displayedArtistName does not satisfy the check",
            !PlaybackStoreProjectionContract.containsUncommented(
                "var displayedArtistName: String { artistName }\n/* \(expectedArtist) */",
                expectedArtist
            )
        )

        check.noThrow("production CurrentTrackRow VoiceOver uses displayed projections") {
            let sources = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let panel = try String(
                contentsOf: sources.appending(path: "Aural/Views/SidePanelView.swift"),
                encoding: .utf8
            )
            let projections = try String(
                contentsOf: sources.appending(path: "Aural/Spotify/PlaybackStore+Projections.swift"),
                encoding: .utf8
            )
            check.check(
                "production VoiceOver label uses displayedTrackTitle and displayedArtistName",
                PlaybackStoreProjectionContract.containsUncommented(panel, expectedLabel)
            )
            check.check(
                "displayedTrackTitle prefers catalog then engine fallback",
                PlaybackStoreProjectionContract.containsUncommented(projections, expectedTitle)
            )
            check.check(
                "displayedArtistName prefers catalog then engine fallback",
                PlaybackStoreProjectionContract.containsUncommented(projections, expectedArtist)
            )
        }
    }
}
