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
            PlaybackStoreProjectionContract.explicitSetterLines(in: writable),
            ["            set { state.session = newValue }"]
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
    }
}
