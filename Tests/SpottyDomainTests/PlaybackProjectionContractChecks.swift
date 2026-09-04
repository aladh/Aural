import Testing
import Foundation

@Suite("Playback Projection Contract")
struct PlaybackProjectionContractTests {
    @Test
    func testPlaybackProjectionContract() {
        do {
            let writable = """
                var phase: Phase {
                    get { state.session }
                    set { state.session = newValue }
                }
                """
            #expect(
                (PlaybackStoreProjectionContract.explicitSetterLines(in: writable)
                    .map { $0.trimmingCharacters(in: .whitespaces) }) == (["set { state.session = newValue }"]),
                "an explicit setter on a projection is reported")
            #expect(
                (PlaybackStoreProjectionContract.isExplicitSetterLine(
                    "        set(newValue) { state.session = newValue }"
                )) == true, "a parameterized setter is reported")

            let projectionsFile = """
                extension PlaybackStore {
                    var phase: Phase { state.session }
                    var trackURI: String { state.currentTrack?.uri ?? "" }
                    func displayedPosition(at date: Date) -> TimeInterval { position }
                }
                """
            #expect(
                (PlaybackStoreProjectionContract.explicitSetterLines(in: projectionsFile)) == ([]),
                "read-only projection files have no setter lines")
            #expect(
                (!PlaybackStoreProjectionContract.isExplicitSetterLine(
                    "    func setNotice(_ message: String?) {}"
                )) == true, "set* methods are not setter accessors")
            #expect(
                (!PlaybackStoreProjectionContract.isExplicitSetterLine("        didSet { }")) == true,
                "didSet observers are not setter accessors")
            #expect(
                (PlaybackStoreProjectionContract.isExplicitSetterLine(
                    "    var phase: Phase { get { state.session } set { state.session = newValue } }"
                )) == true, "an inline get/set accessor is reported")
            #expect(
                (PlaybackStoreProjectionContract.explicitSetterLines(
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
                )) == ([]), "comment and string near-misses do not produce setter lines")
            #expect(
                (PlaybackStoreProjectionContract.explicitSetterLines(
                    in: #"""
                        let documented = """
                        set { ignored }
                        """
                            set { state.session = newValue }
                        """#
                ).map { $0.trimmingCharacters(in: .whitespaces) }) == (["set { state.session = newValue }"]),
                "an accessor after a multiline string is still reported")

            do {
                do {
                    let projectionsURL = URL(fileURLWithPath: #filePath)
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appending(path: "Sources")
                        .appending(path: "Spotty/Spotify/PlaybackStore+Projections.swift")
                    let source = try String(contentsOf: projectionsURL, encoding: .utf8)
                    #expect(
                        (PlaybackStoreProjectionContract.explicitSetterLines(in: source)) == ([]),
                        "production PlaybackStore projections have no explicit setters")

                } catch {
                    Issue.record("\("production PlaybackStore projections are readable"): unexpected error \(error)")
                }
            }
        }

        do {
            let expectedLabel = ".accessibilityLabel(currentTrackAccessibilityLabel)"
            let expectedIdentity =
                "let identity = \"Now playing \\(player.displayedTrackTitle) by \\(player.displayedArtistName)\""
            let expectedDuration = "return \"\\(identity), \\(formatDuration(player.duration))\""
            let expectedUpcomingDuration =
                "let durationText = track.flatMap { $0.duration > 0 ? formatDuration($0.duration) : nil }"
            let expectedUpcomingLabel =
                "[displayInfo.title, subtitle, durationText].compactMap { $0 }.joined(separator: \", \")"
            let expectedTitle =
                "var displayedTrackTitle: String { catalogCurrentTrack?.title ?? trackTitle }"
            let expectedArtist =
                "var displayedArtistName: String { catalogCurrentTrack?.artist ?? artistName }"

            #expect(
                (!PlaybackStoreProjectionContract.containsUncommented(
                    ".accessibilityLabel(\"fallback\") // \(expectedLabel)",
                    expectedLabel
                )) == true, "a line-commented expected label does not satisfy the check")
            #expect(
                (!PlaybackStoreProjectionContract.containsUncommented(
                    ".accessibilityLabel(\"fallback\")\n/* \(expectedLabel) */",
                    expectedLabel
                )) == true, "a block-commented expected label does not satisfy the check")
            #expect(
                (PlaybackStoreProjectionContract.containsUncommented("        \(expectedLabel)\n", expectedLabel))
                    == true,
                "an active expected label satisfies the check")
            #expect(
                (PlaybackStoreProjectionContract.containsUncommented(
                    "let marker = \"/*\"\n        \(expectedLabel)\n",
                    expectedLabel
                )) == true, "a quoted block-comment marker does not hide an active expected label")
            #expect(
                (PlaybackStoreProjectionContract.containsUncommented(
                    "let artwork = \"https://example.invalid/track\"\n        \(expectedLabel)\n",
                    expectedLabel
                )) == true, "a quoted URL does not hide an active expected label")
            #expect(
                (!PlaybackStoreProjectionContract.containsUncommented(
                    "var displayedTrackTitle: String { trackTitle } // \(expectedTitle)",
                    expectedTitle
                )) == true, "a line-commented displayedTrackTitle does not satisfy the check")
            #expect(
                (!PlaybackStoreProjectionContract.containsUncommented(
                    "var displayedTrackTitle: String { trackTitle }\n/* \(expectedTitle) */",
                    expectedTitle
                )) == true, "a block-commented displayedTrackTitle does not satisfy the check")
            #expect(
                (!PlaybackStoreProjectionContract.containsUncommented(
                    "var displayedArtistName: String { artistName } // \(expectedArtist)",
                    expectedArtist
                )) == true, "a line-commented displayedArtistName does not satisfy the check")
            #expect(
                (!PlaybackStoreProjectionContract.containsUncommented(
                    "var displayedArtistName: String { artistName }\n/* \(expectedArtist) */",
                    expectedArtist
                )) == true, "a block-commented displayedArtistName does not satisfy the check")

            do {
                do {
                    let sources = URL(fileURLWithPath: #filePath)
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appending(path: "Sources")
                    let panel = try String(
                        contentsOf: sources.appending(path: "Spotty/Views/SidePanelView.swift"),
                        encoding: .utf8
                    )
                    let projections = try String(
                        contentsOf: sources.appending(path: "Spotty/Spotify/PlaybackStore+Projections.swift"),
                        encoding: .utf8
                    )
                    #expect(
                        (PlaybackStoreProjectionContract.containsUncommented(panel, expectedLabel)) == true,
                        "production VoiceOver label uses the duration-aware helper")
                    #expect(
                        (PlaybackStoreProjectionContract.containsUncommented(panel, expectedIdentity)) == true,
                        "production VoiceOver identity uses displayedTrackTitle and displayedArtistName")
                    #expect(
                        (PlaybackStoreProjectionContract.containsUncommented(panel, expectedDuration)) == true,
                        "production VoiceOver identity includes a valid duration")
                    #expect(
                        (PlaybackStoreProjectionContract.containsUncommented(panel, expectedUpcomingDuration)) == true,
                        "upcoming queue VoiceOver computes a valid duration")
                    #expect(
                        (PlaybackStoreProjectionContract.containsUncommented(panel, expectedUpcomingLabel)) == true,
                        "upcoming queue VoiceOver includes its displayed duration")
                    #expect(
                        (PlaybackStoreProjectionContract.containsUncommented(projections, expectedTitle)) == true,
                        "displayedTrackTitle prefers catalog then engine fallback")
                    #expect(
                        (PlaybackStoreProjectionContract.containsUncommented(projections, expectedArtist)) == true,
                        "displayedArtistName prefers catalog then engine fallback")

                } catch {
                    Issue.record(
                        "\("production CurrentTrackRow VoiceOver uses displayed projections"): unexpected error \(error)"
                    )
                }
            }
        }
    }
}
