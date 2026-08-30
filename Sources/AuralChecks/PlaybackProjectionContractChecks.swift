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

        check.check(
            "catalog enrichment prefers catalog title then engine fallback",
            PlaybackStoreProjectionContract.displayedTrackTitlePrefersCatalog(
                in: "    var displayedTrackTitle: String { catalogCurrentTrack?.title ?? trackTitle }"
            )
        )
        check.check(
            "catalog enrichment prefers catalog artist then engine fallback",
            PlaybackStoreProjectionContract.displayedArtistNamePrefersCatalog(
                in: "    var displayedArtistName: String { catalogCurrentTrack?.artist ?? artistName }"
            )
        )
        check.check(
            "a raw engine title projection is not catalog-enriched",
            !PlaybackStoreProjectionContract.displayedTrackTitlePrefersCatalog(
                in: "    var displayedTrackTitle: String { trackTitle }"
            )
        )
        check.check(
            "a raw engine artist projection is not catalog-enriched",
            !PlaybackStoreProjectionContract.displayedArtistNamePrefersCatalog(
                in: "    var displayedArtistName: String { artistName }"
            )
        )

        check.noThrow("production projection sources prefer catalog enrichment") {
            let projections = try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appending(path: "Aural/Spotify/PlaybackStore+Projections.swift"),
                encoding: .utf8
            )
            check.check(
                "production displayedTrackTitle prefers catalog then engine fallback",
                PlaybackStoreProjectionContract.displayedTrackTitlePrefersCatalog(in: projections)
            )
            check.check(
                "production displayedArtistName prefers catalog then engine fallback",
                PlaybackStoreProjectionContract.displayedArtistNamePrefersCatalog(in: projections)
            )
        }
    }

    check.suite("CurrentTrackRow accessibility contract") {
        let alignedRow = """
            private struct CurrentTrackRow: View {
                var body: some View {
                    Text(player.displayedTrackTitle)
                    Text(player.displayedArtistName)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Now playing \\(player.displayedTrackTitle) by \\(player.displayedArtistName)")
                }
            }
            """
        check.check(
            "an aligned row uses displayed projections in the VoiceOver label",
            CurrentTrackRowAccessibilityContract.accessibilityLabelUsesDisplayedProjections(in: alignedRow)
        )
        check.check(
            "an aligned row still combines children",
            CurrentTrackRowAccessibilityContract.combinesChildren(in: alignedRow)
        )
        check.check(
            "an aligned row does not use raw engine fallbacks",
            !CurrentTrackRowAccessibilityContract.usesRawEngineFallbacks(in: alignedRow)
        )

        let staleRow = """
            private struct CurrentTrackRow: View {
                var body: some View {
                    Text(player.displayedTrackTitle)
                    .accessibilityLabel("Now playing \\(player.trackTitle) by \\(player.artistName)")
                }
            }
            """
        check.check(
            "a VoiceOver label on raw engine fallbacks is reported",
            !CurrentTrackRowAccessibilityContract.accessibilityLabelUsesDisplayedProjections(in: staleRow)
                && CurrentTrackRowAccessibilityContract.usesRawEngineFallbacks(in: staleRow)
        )

        let idleGated = """
            if player.hasCurrentTrack {
                Section("Now playing") {
                    CurrentTrackRow(player: player)
                }
            }
            """
        check.check(
            "the now-playing row stays gated on hasCurrentTrack",
            CurrentTrackRowAccessibilityContract.currentTrackRowIsIdleGated(in: idleGated)
        )
        check.check(
            "an ungated now-playing row is reported",
            !CurrentTrackRowAccessibilityContract.currentTrackRowIsIdleGated(
                in: "Section(\"Now playing\") { CurrentTrackRow(player: player) }"
            )
        )

        let named = CurrentTrackRowAccessibilityContract.typeBody(
            named: "CurrentTrackRow",
            in: "private struct Other: View { }\nprivate struct CurrentTrackRow: View { let x = 1 }\n"
        )
        check.equal("the named type body is extracted", named, "{ let x = 1 }")

        check.noThrow("production CurrentTrackRow VoiceOver uses displayed projections") {
            let panel = try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appending(path: "Aural/Views/SidePanelView.swift"),
                encoding: .utf8
            )
            let row = CurrentTrackRowAccessibilityContract.typeBody(named: "CurrentTrackRow", in: panel)
            check.check("CurrentTrackRow is present", row != nil)
            if let row {
                check.check(
                    "production VoiceOver label uses displayedTrackTitle and displayedArtistName",
                    CurrentTrackRowAccessibilityContract.accessibilityLabelUsesDisplayedProjections(in: row)
                )
                check.check(
                    "production CurrentTrackRow still combines children",
                    CurrentTrackRowAccessibilityContract.combinesChildren(in: row)
                )
                check.check(
                    "production CurrentTrackRow does not announce raw engine fallbacks",
                    !CurrentTrackRowAccessibilityContract.usesRawEngineFallbacks(in: row)
                )
            }
            check.check(
                "production now-playing row is omitted while idle",
                CurrentTrackRowAccessibilityContract.currentTrackRowIsIdleGated(in: panel)
            )

            let upcoming = CurrentTrackRowAccessibilityContract.typeBody(named: "QueueUpcomingRow", in: panel) ?? ""
            let history = CurrentTrackRowAccessibilityContract.typeBody(named: "HistoryRow", in: panel) ?? ""
            check.check(
                "upcoming queue VoiceOver stays title and subtitle",
                CurrentTrackRowAccessibilityContract.collapsed(upcoming)
                    .contains(".accessibilityLabel(\"\\(title), \\(subtitle)\")")
            )
            check.check(
                "history VoiceOver stays play-by-relative phrasing",
                CurrentTrackRowAccessibilityContract.collapsed(history).contains(
                    ".accessibilityLabel(\"Play \\(entry.title) by \\(entry.artist), played \\(entry.playedAt.formatted(.relative(presentation: .named)))\")"
                )
            )
        }
    }
}
