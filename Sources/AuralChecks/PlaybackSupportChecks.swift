import AuralDomain
import Foundation

func runPlaybackSupportChecks(_ check: CheckRunner) {
    check.suite("Smooth playback position") {
        let anchorDate = Date(timeIntervalSince1970: 1_000)
        check.equal(
            "playing advances between backend samples",
            interpolatedPlaybackPosition(anchor: 40, anchoredAt: anchorDate, now: anchorDate.addingTimeInterval(0.25), isPlaying: true, duration: 200),
            40.25
        )
        check.equal(
            "paused position stays anchored",
            interpolatedPlaybackPosition(anchor: 40, anchoredAt: anchorDate, now: anchorDate.addingTimeInterval(10), isPlaying: false, duration: 200),
            40
        )
        check.equal(
            "interpolation stops at track duration",
            interpolatedPlaybackPosition(anchor: 199.8, anchoredAt: anchorDate, now: anchorDate.addingTimeInterval(1), isPlaying: true, duration: 200),
            200
        )
        check.equal(
            "clock reversal cannot move the playhead backward",
            interpolatedPlaybackPosition(anchor: 40, anchoredAt: anchorDate, now: anchorDate.addingTimeInterval(-1), isPlaying: true, duration: 200),
            40
        )

        let receivedAt = Date(timeIntervalSince1970: 1_010)
        check.equal(
            "playing Connect snapshots compensate for their timestamp",
            playbackSnapshotPosition(positionMilliseconds: 40_000, durationMilliseconds: 200_000, timestampMilliseconds: 1_005_000, isPlaying: true, now: receivedAt),
            45
        )
        check.equal(
            "paused Connect snapshots stay at their exact position",
            playbackSnapshotPosition(positionMilliseconds: 40_000, durationMilliseconds: 200_000, timestampMilliseconds: 1_005_000, isPlaying: false, now: receivedAt),
            40
        )
    }

    check.suite("Repeat mode") {
        let cycle: [RepeatMode] = [.off, .context, .track, .off]
        for (before, after) in zip(cycle, cycle.dropFirst()) {
            check.equal("cycle \(before) → \(after)", before.next, after)
        }
        check.equal("backend flags for context repeat", RepeatMode.context.flags, RepeatFlags(context: true, track: false))
        check.equal("backend flags for track repeat", RepeatMode.track.flags, RepeatFlags(context: false, track: true))
        check.equal("backend flags for no repeat", RepeatMode.off.flags, RepeatFlags(context: false, track: false))
        check.equal("flags rebuild to context", RepeatMode(context: true, track: false), .context)
        check.equal("track flag wins over context", RepeatMode(context: true, track: true), .track)
        check.equal("flags rebuild to off", RepeatMode(context: false, track: false), .off)
    }

    check.suite("Play history") {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var entries = PlaybackHistory.updated([], afterPlaying: "spotify:track:a", title: "A", artist: "X", artworkURLString: nil, playedAt: now)
        check.equal("newest entry lands first", entries.first?.uri, "spotify:track:a")

        entries = PlaybackHistory.updated(entries, afterPlaying: "spotify:track:a", title: "A", artist: "X", artworkURLString: nil, playedAt: now.addingTimeInterval(60))
        check.equal("replay does not duplicate", entries.count, 1)
        check.equal("replay refreshes the timestamp", entries.first?.playedAt, now.addingTimeInterval(60))

        entries = PlaybackHistory.withMetadata(entries, for: "spotify:track:a", title: "Real Title", artist: "Real Artist", artworkURLString: "https://example/a.jpg")
        check.equal("late metadata fills the title", entries.first?.title, "Real Title")
        check.equal("late metadata keeps other fields", entries.first?.playedAt, now.addingTimeInterval(60))

        entries = (0..<PlaybackHistory.cap + 25).reversed().reduce(entries) { current, index in
            PlaybackHistory.updated(current, afterPlaying: "spotify:track:\(index)", title: "T\(index)", artist: "", artworkURLString: nil, playedAt: now.addingTimeInterval(TimeInterval(index)))
        }
        check.equal("history is capped", entries.count, PlaybackHistory.cap)

        var capped: [HistoryEntry] = []
        for index in 0..<PlaybackHistory.cap {
            capped = PlaybackHistory.updated(capped, afterPlaying: "spotify:track:t\(index)", title: "T\(index)", artist: "", artworkURLString: nil, playedAt: now.addingTimeInterval(TimeInterval(index)))
        }
        capped = PlaybackHistory.updated(capped, afterPlaying: "spotify:track:new", title: "New", artist: "", artworkURLString: nil, playedAt: now.addingTimeInterval(999))
        check.equal("cap boundary stays at the cap", capped.count, PlaybackHistory.cap)
        check.equal("the new track lands on top", capped.first?.uri, "spotify:track:new")
        check.equal("exactly the oldest row falls off", capped.last?.uri, "spotify:track:t1")

        var lifted: [HistoryEntry] = []
        for suffix in ["a", "b", "c"] {
            lifted = PlaybackHistory.updated(lifted, afterPlaying: "spotify:track:\(suffix)", title: suffix.uppercased(), artist: "", artworkURLString: nil, playedAt: now)
        }
        lifted = PlaybackHistory.updated(lifted, afterPlaying: "spotify:track:a", title: "A", artist: "", artworkURLString: nil, playedAt: now.addingTimeInterval(30))
        check.equal("a buried replay moves to the front", lifted.first?.uri, "spotify:track:a")
        check.equal("the lift does not duplicate", lifted.count, 3)
        check.equal("the other rows keep their order", lifted.last?.uri, "spotify:track:b")

        let untouched = [HistoryEntry(uri: "spotify:track:kept", title: "Kept", artist: "K", artworkURLString: nil, playedAt: now)]
        let afterMiss = PlaybackHistory.withMetadata(untouched, for: "spotify:track:other", title: "X", artist: "Y", artworkURLString: "https://example/x.jpg")
        check.equal("metadata for an absent uri changes nothing", afterMiss, untouched)

        let owned = [HistoryEntry(uri: "spotify:track:a", title: "A", artist: "X", artworkURLString: "https://example/old.jpg", playedAt: now)]
        let enriched = PlaybackHistory.withMetadata(owned, for: "spotify:track:a", title: "Better Title", artist: "X", artworkURLString: "https://example/new.jpg")
        check.equal("known artwork survives enrichment", enriched.first?.artworkURLString, "https://example/old.jpg")
        check.equal("non-empty titles still update", enriched.first?.title, "Better Title")
    }

    check.suite("Queue and device policy") {
        let queued = QueueEntry(uri: "spotify:track:a", provider: "queue")
        let suggested = QueueEntry(uri: "spotify:track:b", provider: "autoplay")
        let contextual = QueueEntry(uri: "spotify:track:c", provider: "context")
        let documented = QueueEntry(uri: "spotify:track:d", provider: "web-api")
        check.check(
            "providers map to listener labels",
            queued.sourceLabel == "From your queue"
                && suggested.sourceLabel == "Suggested by Spotify"
                && contextual.sourceLabel == "From the current context"
                && documented.sourceLabel == "Up next"
        )
        let repeated = [
            QueueEntry(uri: "spotify:track:a", provider: "queue", occurrence: 0),
            QueueEntry(uri: "spotify:track:a", provider: "queue", occurrence: 1),
        ]
        check.check("duplicate queue tracks have distinct row identities", repeated[0].id != repeated[1].id)

        let local = ConnectDevice(id: "local", name: "Aural", type: "computer", isActive: false)
        let remote = ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
        check.equal("local device is identified even while inactive", local.displayName(localDeviceID: "local"), "Aural (This Mac)")
        check.equal("active remote device is identified as playing", remote.displayName(localDeviceID: "local"), "Phone (Playing)")
        check.equal(
            "transport routes to the active remote device",
            connectCommandRoute(isLocalActive: false, localDeviceID: "local", devices: [local, remote]),
            .remote(from: "local", to: "phone")
        )
        check.equal(
            "remote commands wait for this device identity",
            connectCommandRoute(isLocalActive: false, localDeviceID: nil, devices: [remote]),
            .waitingForLocalIdentity
        )
        check.equal(
            "no active remote keeps local playback available",
            connectCommandRoute(isLocalActive: false, localDeviceID: "local", devices: [local]),
            .local
        )
        check.equal(
            "paused playback retains its remote command target",
            connectCommandRoute(
                isLocalActive: false,
                localDeviceID: "local",
                devices: [local, ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: false)],
                fallbackRemoteDeviceID: "phone"
            ),
            .remote(from: "local", to: "phone")
        )
        let remoteOwner = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")
        check.equal(
            "explicit remote ownership routes remotely",
            connectCommandRoute(owner: .remote(remoteOwner), localDeviceID: "local"),
            .remote(from: "local", to: "phone")
        )
        check.equal(
            "an uncertain paused remote remains routable",
            connectCommandRoute(owner: .uncertain(remoteOwner), localDeviceID: "local"),
            .remote(from: "local", to: "phone")
        )
        check.equal(
            "an unidentified owner cannot accidentally steal playback",
            connectCommandRoute(owner: .uncertain(nil), localDeviceID: "local"),
            .waitingForLocalIdentity
        )

        let inactivePhone = PlaybackDevice(
            id: "phone",
            name: "Phone",
            type: "smartphone",
            isActive: false
        )
        let metadataLateOwner = connectionPlaybackOwner(
            isLocalActive: false,
            localDeviceID: "local",
            localDeviceName: "Aural",
            devices: [PlaybackDevice(id: "local", name: "Aural", type: "computer"), inactivePhone],
            currentTrackURI: "spotify:track:metadata-late",
            previousOwner: .none,
            lastRemoteDeviceID: "phone"
        )
        check.equal(
            "a metadata-late remote track retains an uncertain remote identity",
            metadataLateOwner,
            .uncertain(inactivePhone)
        )
        check.equal(
            "the metadata-late owner routes remotely instead of stealing playback",
            connectCommandRoute(owner: metadataLateOwner, localDeviceID: "local"),
            .remote(from: "local", to: "phone")
        )

        check.nil_(
            "a cached queue for an older track cannot replace playback identity",
            queueBootstrapMetadataURI(
                snapshotTrackURI: "spotify:track:old",
                currentTrackURI: "spotify:track:new"
            )
        )
        check.equal(
            "a cached queue may enrich only the matching current track",
            queueBootstrapMetadataURI(
                snapshotTrackURI: "spotify:track:new",
                currentTrackURI: "spotify:track:new"
            ),
            "spotify:track:new"
        )
    }

    check.suite("Termination policy") {
        var gate = PlaybackTerminationGate()
        check.check("commands are admitted before termination", gate.allowsCommands)
        check.check("the first termination request owns shutdown", gate.begin())
        check.check("commands are rejected once termination begins", !gate.allowsCommands)
        check.check("a second termination request cannot start another shutdown", !gate.begin())
    }

    check.suite("PCM ring buffer cursor") {
        var cursor = PCMBufferCursor(capacity: 8)
        check.equal("an empty cursor has no available samples", cursor.available, 0)
        check.equal("one slot distinguishes full from empty", cursor.free, 7)

        cursor.advanceWrite(by: 6)
        cursor.advanceRead(by: 5)
        cursor.advanceWrite(by: 1)
        check.equal("wrapped writes preserve the available count", cursor.available, 2)
        check.equal("write index wraps at capacity", cursor.writeIndex, 7)

        cursor.advanceRead(by: 2)
        cursor.advanceWrite(by: 7)
        check.equal("the cursor can represent a full ring", cursor.available, 7)
        check.equal("a full ring has no writable slots", cursor.free, 0)

        cursor.reset()
        check.equal("reset clears the read index", cursor.readIndex, 0)
        check.equal("reset clears the write index", cursor.writeIndex, 0)
        check.equal("reset restores full writable capacity", cursor.free, 7)
    }

    check.suite("PCM write backpressure") {
        var policy = PCMWriteBackpressure()
        check.equal(
            "free space admits a partial write",
            policy.admit(freeSpace: 8, remaining: 3, isRendering: true),
            .write(3)
        )
        check.equal(
            "admission never copies more than free space",
            policy.admit(freeSpace: 2, remaining: 9, isRendering: true),
            .write(2)
        )

        var stopped = PCMWriteBackpressure()
        check.equal(
            "a stopped renderer drops a full buffer instead of waiting",
            stopped.admit(freeSpace: 0, remaining: 4, isRendering: false),
            .dropRemaining
        )

        var full = PCMWriteBackpressure()
        var waitCount = 0
        var remaining = 16
        var controlRan = false
        while remaining > 0 {
            switch full.admit(freeSpace: 0, remaining: remaining, isRendering: true) {
            case .write(_):
                check.check("a full rendering buffer cannot admit a write", false)
                remaining = 0
                remaining = 0
            case .waitForSpace:
                waitCount += 1
                if waitCount > PCMWriteBackpressure.maxConsecutiveFullWaits {
                    check.check("wait admission is bounded", false)
                    remaining = 0
                }
            case .dropRemaining:
                remaining = 0
                controlRan = true
            }
        }
        check.equal(
            "a full buffer waits one budget then drops instead of looping",
            waitCount,
            PCMWriteBackpressure.maxConsecutiveFullWaits
        )
        check.check("control can run on the writer thread after the drop", controlRan)

        var recovered = full
        check.equal(
            "space after a drop resets the wait budget",
            recovered.admit(freeSpace: 5, remaining: 5, isRendering: true),
            .write(5)
        )
        check.equal(
            "after a drop, a still-full buffer keeps dropping until space or reset",
            full.admit(freeSpace: 0, remaining: 1, isRendering: true),
            .dropRemaining
        )
        full.resetWaitBudget()
        check.equal(
            "flush reset allows a later full buffer to wait again",
            full.admit(freeSpace: 0, remaining: 1, isRendering: true),
            .waitForSpace
        )
    }

    check.suite("PCM writer space wake") {
        let bypass = PCMWriteSpace()
        bypass.signal()
        check.check(
            "stop or flush before wait bypasses the parked writer",
            bypass.wait(timeoutMilliseconds: 0)
        )

        let idle = PCMWriteSpace()
        check.check(
            "a wait with no signal times out without spinning",
            !idle.wait(timeoutMilliseconds: 0)
        )

        let space = PCMWriteSpace()
        let finished = DispatchSemaphore(value: 0)
        let woke = PCMWriterWakeFlag()
        Thread.detachNewThread {
            woke.store(space.wait(timeoutMilliseconds: 5_000))
            finished.signal()
        }
        space.signal()
        check.check(
            "stop or flush wakes a waiting writer",
            finished.wait(timeout: .now() + .seconds(5)) == .success
        )
        check.check("the waiting writer observes the control signal", woke.load())
    }
}

private final class PCMWriterWakeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func store(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
