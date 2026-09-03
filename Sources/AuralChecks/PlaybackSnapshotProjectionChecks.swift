import AuralDomain
import Foundation

func runPlaybackSnapshotProjectionChecks(_ check: CheckRunner) {
    let receivedAt = Date(timeIntervalSince1970: 1_010)

    check.suite("Playback snapshot projection") {
        check.nil_("an empty wire URI is missing", PlaybackSnapshotProjection.resolvedTrackURI(""))
        check.equal(
            "a nonempty wire URI is kept",
            PlaybackSnapshotProjection.resolvedTrackURI("spotify:track:now"),
            "spotify:track:now"
        )
        check.nil_(
            "an empty context URI is missing",
            PlaybackSnapshotProjection.resolvedContextURI("")
        )
        check.equal(
            "a nonempty context URI is kept",
            PlaybackSnapshotProjection.resolvedContextURI("spotify:playlist:ctx"),
            "spotify:playlist:ctx"
        )

        check.check(
            "playing and not paused is audible",
            PlaybackSnapshotProjection.isAudible(isPlaying: true, isPaused: false)
        )
        check.check(
            "playing and paused is not audible",
            !PlaybackSnapshotProjection.isAudible(isPlaying: true, isPaused: true)
        )
        check.check(
            "not playing is not audible",
            !PlaybackSnapshotProjection.isAudible(isPlaying: false, isPaused: false)
        )

        check.equal(
            "audible playback with a track is playing",
            PlaybackSnapshotProjection.transport(
                isPlaying: true,
                isPaused: false,
                trackURI: "spotify:track:now",
                isInitialSnapshot: false,
                isActiveDevice: true
            ),
            .playing
        )
        check.equal(
            "the first local snapshot does not present playing",
            PlaybackSnapshotProjection.transport(
                isPlaying: true,
                isPaused: false,
                trackURI: "spotify:track:now",
                isInitialSnapshot: true,
                isActiveDevice: true
            ),
            .paused
        )
        check.equal(
            "the first remote snapshot may present playing",
            PlaybackSnapshotProjection.transport(
                isPlaying: true,
                isPaused: false,
                trackURI: "spotify:track:now",
                isInitialSnapshot: true,
                isActiveDevice: false
            ),
            .playing
        )
        check.equal(
            "playing and paused together is paused when a track is present",
            PlaybackSnapshotProjection.transport(
                isPlaying: true,
                isPaused: true,
                trackURI: "spotify:track:now",
                isInitialSnapshot: false,
                isActiveDevice: false
            ),
            .paused
        )
        check.equal(
            "no track and no audible playback is stopped",
            PlaybackSnapshotProjection.transport(
                isPlaying: false,
                isPaused: false,
                trackURI: "",
                isInitialSnapshot: false,
                isActiveDevice: false
            ),
            .stopped
        )
        check.equal(
            "audible playback with an empty URI stays playing",
            PlaybackSnapshotProjection.transport(
                isPlaying: true,
                isPaused: false,
                trackURI: "",
                isInitialSnapshot: false,
                isActiveDevice: false
            ),
            .playing
        )
        let emptyURIPlaying = PlaybackSnapshotProjection.snapshot(
            isPlaying: true,
            isPaused: false,
            trackURI: "",
            contextURI: "",
            positionMilliseconds: 40_000,
            durationMilliseconds: 200_000,
            timestampMilliseconds: 1_005_000,
            shuffle: false,
            repeatContext: false,
            repeatTrack: false,
            previousRepeat: RepeatFlags(context: false, track: false),
            isInitialSnapshot: false,
            isActiveDevice: false,
            receivedAt: receivedAt
        )
        check.equal("empty-URI audible snapshot stays playing", emptyURIPlaying.transport, .playing)
        check.nil_("empty-URI audible snapshot has no track identity", emptyURIPlaying.trackURI)
        check.nil_("empty-URI audible snapshot has no context identity", emptyURIPlaying.contextURI)
        check.equal(
            "a paused track is paused",
            PlaybackSnapshotProjection.transport(
                isPlaying: false,
                isPaused: true,
                trackURI: "spotify:track:now",
                isInitialSnapshot: false,
                isActiveDevice: true
            ),
            .paused
        )

        let previous = RepeatFlags(context: true, track: false)
        check.equal(
            "omitted repeat flags keep the previous pair",
            PlaybackSnapshotProjection.repeatFlags(context: nil, track: nil, previous: previous),
            previous
        )
        check.equal(
            "present repeat flags replace the previous pair",
            PlaybackSnapshotProjection.repeatFlags(context: false, track: true, previous: previous),
            RepeatFlags(context: false, track: true)
        )

        let snapshot = PlaybackSnapshotProjection.snapshot(
            isPlaying: true,
            isPaused: false,
            trackURI: "spotify:track:now",
            contextURI: "spotify:playlist:ctx",
            positionMilliseconds: 40_000,
            durationMilliseconds: 200_000,
            timestampMilliseconds: 1_005_000,
            shuffle: true,
            repeatContext: true,
            repeatTrack: false,
            previousRepeat: RepeatFlags(context: false, track: false),
            isInitialSnapshot: false,
            isActiveDevice: false,
            receivedAt: receivedAt
        )
        check.equal("a live remote snapshot presents playing", snapshot.transport, .playing)
        check.equal("snapshot track identity drops empty URIs", snapshot.trackURI, "spotify:track:now")
        check.equal(
            "snapshot context identity drops empty URIs",
            snapshot.contextURI,
            "spotify:playlist:ctx"
        )
        check.equal("playing snapshots compensate for their timestamp", snapshot.timing.position, 45)
        check.equal("snapshot duration is seconds", snapshot.timing.duration, 200)
        check.equal("snapshot shuffle is forwarded", snapshot.shuffle, true)
        check.equal("snapshot repeat mode follows the wire flags", snapshot.repeatMode, .context)
        check.equal(
            "snapshot repeat flags follow the wire",
            snapshot.repeatFlags,
            RepeatFlags(context: true, track: false)
        )

        let firstLocal = PlaybackSnapshotProjection.snapshot(
            isPlaying: true,
            isPaused: false,
            trackURI: "spotify:track:now",
            contextURI: "spotify:playlist:ctx",
            positionMilliseconds: 40_000,
            durationMilliseconds: 200_000,
            timestampMilliseconds: 1_005_000,
            shuffle: false,
            repeatContext: false,
            repeatTrack: false,
            previousRepeat: RepeatFlags(context: false, track: false),
            isInitialSnapshot: true,
            isActiveDevice: true,
            receivedAt: receivedAt
        )
        check.equal("first-local snapshot() presents paused", firstLocal.transport, .paused)
        check.equal("first-local snapshot() does not interpolate position", firstLocal.timing.position, 40)
    }
}
