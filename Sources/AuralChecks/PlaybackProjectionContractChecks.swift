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
            "a line-comment setter example is not an accessor",
            !PlaybackStoreProjectionContract.isExplicitSetterLine(
                "        // set { state.session = newValue }"
            )
        )
        check.check(
            "a trailing comment setter example is not an accessor",
            !PlaybackStoreProjectionContract.isExplicitSetterLine(
                "        var phase: Phase { state.session } // set { state.session = newValue }"
            )
        )
        check.check(
            "a quoted setter example is not an accessor",
            !PlaybackStoreProjectionContract.isExplicitSetterLine(
                #"        let sample = "set { state.session = newValue }""#
            )
        )
        check.equal(
            "comment and string near-misses do not produce setter lines",
            PlaybackStoreProjectionContract.explicitSetterLines(
                in: """
                    // set { state.session = newValue }
                    var phase: Phase { state.session } // set { }
                    let sample = "set { }"
                    """
            ),
            []
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
}
