import Foundation

func runPlaybackProjectionContractChecks(_ check: CheckRunner) {
    check.suite("PlaybackStore projection contract") {
        let writable = """
        final class PlaybackStore {
            var phase: Phase {
                get { state.session }
                set { state.session = newValue }
            }
        }
        """
        check.equal(
            "a writable projection is reported by name",
            PlaybackStoreProjectionContract.writableComputedProperties(in: writable),
            ["phase"]
        )

        let readOnly = """
        final class PlaybackStore {
            var phase: Phase { state.session }
            var trackURI: String { state.currentTrack?.uri ?? "" }
            var isPlaying: Bool { state.transport == .playing }
            var position: TimeInterval { state.timing.position }
            var statusText: String { "ready" }
            var thisDeviceName = "This Mac"
            func setNotice(_ message: String?) {}
            func setTransport(_ transport: PlaybackTransportState) {}
        }
        """
        check.equal(
            "read-only projections have no setters",
            PlaybackStoreProjectionContract.writableComputedProperties(in: readOnly),
            []
        )

        let unrelated = """
        nonisolated struct RustPlaybackState {
            var revision: UInt64?
            var isPaused: Bool? {
                get { nil }
                set { _ = newValue }
            }
        }
        final class PlaybackStore {
            var phase: Phase { state.session }
            func setPresentation() {
                var next = state
                next = state
            }
        }
        extension PlaybackStore {
            var trackURI: String { "" }
        }
        """
        check.equal(
            "setters on other types and set* methods are ignored",
            PlaybackStoreProjectionContract.writableComputedProperties(in: unrelated),
            []
        )

        if let livePath = ProcessInfo.processInfo.environment["AURAL_PLAYBACK_STORE_SOURCE"] {
            let sources = PlaybackStoreProjectionContract.liveSources(from: livePath)
            check.check("live PlaybackStore sources are readable", !sources.isEmpty)
            let writableLive = sources.flatMap(PlaybackStoreProjectionContract.writableComputedProperties(in:))
            check.equal("live PlaybackStore projections stay read-only", writableLive, [])
            let computed = Set(sources.flatMap(PlaybackStoreProjectionContract.computedProperties(in:)))
            for name in PlaybackStoreProjectionContract.requiredReadOnlyProjections {
                check.check("live PlaybackStore still exposes \(name)", computed.contains(name))
            }
        }
    }
}
