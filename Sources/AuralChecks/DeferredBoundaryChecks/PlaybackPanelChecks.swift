//
//  PlaybackPanelChecks.swift
//  Aural
//

import Foundation
@testable import AuralCore
import enum AuralDomain.QueueProtocolProjection
import struct AuralDomain.QueueProtocolTrack

@MainActor
func runPlaybackPanelChecks(_ check: CheckRunner) {
    check.suite("Smooth playback position") {
        let anchorDate = Date(timeIntervalSince1970: 1_000)
        check.equal(
            "playing advances between backend samples",
            interpolatedPlaybackPosition(
                anchor: 40,
                anchoredAt: anchorDate,
                now: anchorDate.addingTimeInterval(0.25),
                isPlaying: true,
                duration: 200
            ),
            40.25
        )
        check.equal(
            "paused position stays anchored",
            interpolatedPlaybackPosition(
                anchor: 40,
                anchoredAt: anchorDate,
                now: anchorDate.addingTimeInterval(10),
                isPlaying: false,
                duration: 200
            ),
            40
        )
        check.equal(
            "interpolation stops at track duration",
            interpolatedPlaybackPosition(
                anchor: 199.8,
                anchoredAt: anchorDate,
                now: anchorDate.addingTimeInterval(1),
                isPlaying: true,
                duration: 200
            ),
            200
        )
        check.equal(
            "clock reversal cannot move the playhead backward",
            interpolatedPlaybackPosition(
                anchor: 40,
                anchoredAt: anchorDate,
                now: anchorDate.addingTimeInterval(-1),
                isPlaying: true,
                duration: 200
            ),
            40
        )

        let receivedAt = Date(timeIntervalSince1970: 1_010)
        check.equal(
            "playing Connect snapshots compensate for their timestamp",
            playbackSnapshotPosition(
                positionMilliseconds: 40_000,
                durationMilliseconds: 200_000,
                timestampMilliseconds: 1_005_000,
                isPlaying: true,
                now: receivedAt
            ),
            45
        )
        check.equal(
            "paused Connect snapshots stay at their exact position",
            playbackSnapshotPosition(
                positionMilliseconds: 40_000,
                durationMilliseconds: 200_000,
                timestampMilliseconds: 1_005_000,
                isPlaying: false,
                now: receivedAt
            ),
            40
        )
    }

    // Cold-start resolution: backend queue/state events carry uris without names,
    // so the bar's metadata must come from the loaded catalog.
    check.suite("Cold-start track resolution") {
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(
            attributesProvider: TrackAttributesAPI(),
            session: session
        )
        metadata.replaceTracks(
            [
                CatalogTrack(
                    id: "a", uri: "spotify:track:liked", title: "Liked One", artist: "Artist L",
                    album: "Album", duration: 200, artworkURL: nil, addedAt: nil
                )
            ], from: .library)
        metadata.replaceTracks(
            [
                CatalogTrack(
                    id: "b", uri: "spotify:track:searched", title: "Searched One", artist: "Artist S",
                    album: "Album S", duration: 180, artworkURL: URL(string: "https://example/s.jpg"), addedAt: nil
                )
            ], from: .search)
        metadata.replaceTracks(
            [
                CatalogTrack(
                    id: "c", uri: "spotify:track:pl", title: "Playlist One", artist: "Artist P",
                    album: "Album P", duration: 150, artworkURL: nil, addedAt: nil
                )
            ], from: .playlist)

        let liked = metadata.knownTrack(for: "spotify:track:liked")
        check.equal("liked list resolves", liked?.title, "Liked One")
        let searched = metadata.knownTrack(for: "spotify:track:searched")
        check.equal(
            "search results resolve with artwork", searched?.artworkURL?.absoluteString, "https://example/s.jpg")

        let info = metadata.displayInfo(for: "spotify:track:pl")
        check.equal("display info resolves the title", info.title, "Playlist One")

        let unknown = metadata.displayInfo(for: "spotify:track:deadbeef")
        check.equal("unknown uris still name something", unknown.title, "Unknown track")
        check.equal("unknown uris surface their id", unknown.artist, "deadbeef")

        let homePlaylist = CatalogItem(
            id: "home-playlist",
            uri: "spotify:playlist:home",
            title: "Home Playlist",
            subtitle: "Listener",
            artworkURL: nil,
            kind: .playlist
        )
        metadata.replaceItems([homePlaylist], from: .home)
        check.equal(
            "home item lookup stays lazy and resolves", metadata.knownItem(for: homePlaylist.uri)?.title,
            "Home Playlist")

        let queueWaitingForOrdering = SidePanelQueueRefreshIdentity(
            isConnected: true,
            currentTrackURI: "spotify:track:current",
            connectOrderingVersion: 0
        )
        let queueWithOrdering = SidePanelQueueRefreshIdentity(
            isConnected: true,
            currentTrackURI: "spotify:track:current",
            connectOrderingVersion: 1
        )
        check.check(
            "launch-time queue ordering restarts metadata hydration",
            queueWaitingForOrdering != queueWithOrdering
        )
        let queueAfterHydration = SidePanelQueueRefreshIdentity(
            isConnected: true,
            currentTrackURI: "spotify:track:current",
            connectOrderingVersion: queueWithOrdering.connectOrderingVersion
        )
        check.equal(
            "queue hydration does not schedule a second refresh",
            queueAfterHydration,
            queueWithOrdering
        )
    }

    check.suite("Repeat mode") {
        let cycle: [RepeatMode] = [.off, .context, .track, .off]
        for (before, after) in zip(cycle, cycle.dropFirst()) {
            check.equal("cycle \(before) → \(after)", before.next, after)
        }

        check.equal(
            "backend flags for context repeat",
            RepeatMode.context.flags,
            RepeatFlags(context: true, track: false)
        )
        check.equal(
            "backend flags for track repeat",
            RepeatMode.track.flags,
            RepeatFlags(context: false, track: true)
        )
        check.equal(
            "backend flags for no repeat",
            RepeatMode.off.flags,
            RepeatFlags(context: false, track: false)
        )
        // The two backend switches compose back into one mode.
        check.equal("flags rebuild to context", RepeatMode(context: true, track: false), .context)
        check.equal("track flag wins over context", RepeatMode(context: true, track: true), .track)
        check.equal("flags rebuild to off", RepeatMode(context: false, track: false), .off)
    }

    check.suite("Play history") {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = PlaybackHistoryStore()
        store.notePlayed(uri: "spotify:track:a", title: "A", artist: "X", artworkURL: nil, playedAt: now)
        check.equal("history store records the injected playedAt", store.entries.first?.playedAt, now)
        store.notePlayed(
            uri: "spotify:track:a",
            title: "A",
            artist: "X",
            artworkURL: nil,
            playedAt: now.addingTimeInterval(60)
        )
        check.equal("history store replay keeps a single row", store.entries.count, 1)
        check.equal(
            "history store replay uses the later injected timestamp", store.entries.first?.playedAt,
            now.addingTimeInterval(60))

        var entries = PlaybackHistory.updated(
            [], afterPlaying: "spotify:track:a", title: "A", artist: "X", artworkURLString: nil, playedAt: now)
        check.equal("newest entry lands first", entries.first?.uri, "spotify:track:a")

        // Replaying the same track moves it rather than duplicating it.
        entries = PlaybackHistory.updated(
            entries,
            afterPlaying: "spotify:track:a",
            title: "A",
            artist: "X",
            artworkURLString: nil,
            playedAt: now.addingTimeInterval(60)
        )
        check.equal("replay does not duplicate", entries.count, 1)
        check.equal("replay refreshes the timestamp", entries.first?.playedAt, now.addingTimeInterval(60))

        // Metadata arriving late fills the entry in.
        entries = PlaybackHistory.withMetadata(
            entries,
            for: "spotify:track:a",
            title: "Real Title",
            artist: "Real Artist",
            artworkURLString: "https://example/a.jpg"
        )
        check.equal("late metadata fills the title", entries.first?.title, "Real Title")
        check.equal("late metadata keeps other fields", entries.first?.playedAt, now.addingTimeInterval(60))

        // The cap holds.
        entries = (0..<PlaybackHistory.cap + 25).reversed().reduce(entries) { current, index in
            PlaybackHistory.updated(
                current,
                afterPlaying: "spotify:track:\(index)",
                title: "T\(index)",
                artist: "",
                artworkURLString: nil,
                playedAt: now.addingTimeInterval(TimeInterval(index))
            )
        }
        check.equal("history is capped", entries.count, PlaybackHistory.cap)

        // At exactly the cap one more play evicts precisely the oldest row.
        var capped: [HistoryEntry] = []
        for index in 0..<PlaybackHistory.cap {
            capped = PlaybackHistory.updated(
                capped,
                afterPlaying: "spotify:track:t\(index)",
                title: "T\(index)",
                artist: "",
                artworkURLString: nil,
                playedAt: now.addingTimeInterval(TimeInterval(index))
            )
        }
        capped = PlaybackHistory.updated(
            capped,
            afterPlaying: "spotify:track:new",
            title: "New",
            artist: "",
            artworkURLString: nil,
            playedAt: now.addingTimeInterval(999)
        )
        check.equal("cap boundary stays at the cap", capped.count, PlaybackHistory.cap)
        check.equal("the new track lands on top", capped.first?.uri, "spotify:track:new")
        check.equal("exactly the oldest row falls off", capped.last?.uri, "spotify:track:t1")

        // Replaying a buried track lifts it without duplicating or reordering the rest.
        var lifted: [HistoryEntry] = []
        for suffix in ["a", "b", "c"] {
            lifted = PlaybackHistory.updated(
                lifted,
                afterPlaying: "spotify:track:\(suffix)",
                title: suffix.uppercased(),
                artist: "",
                artworkURLString: nil,
                playedAt: now
            )
        }
        lifted = PlaybackHistory.updated(
            lifted,
            afterPlaying: "spotify:track:a",
            title: "A",
            artist: "",
            artworkURLString: nil,
            playedAt: now.addingTimeInterval(30)
        )
        check.equal("a buried replay moves to the front", lifted.first?.uri, "spotify:track:a")
        check.equal("the lift does not duplicate", lifted.count, 3)
        check.equal("the other rows keep their order", lifted.last?.uri, "spotify:track:b")

        // Metadata aimed at one uri must leave every other entry untouched.
        let untouched = [
            HistoryEntry(uri: "spotify:track:kept", title: "Kept", artist: "K", artworkURLString: nil, playedAt: now)
        ]
        let afterMiss = PlaybackHistory.withMetadata(
            untouched,
            for: "spotify:track:other",
            title: "X",
            artist: "Y",
            artworkURLString: "https://example/x.jpg"
        )
        check.equal("metadata for an absent uri changes nothing", afterMiss, untouched)

        // Artwork already known is never downgraded by a later fill-in.
        let owned = [
            HistoryEntry(
                uri: "spotify:track:a", title: "A", artist: "X",
                artworkURLString: "https://example/old.jpg", playedAt: now
            )
        ]
        let enriched = PlaybackHistory.withMetadata(
            owned,
            for: "spotify:track:a",
            title: "Better Title",
            artist: "X",
            artworkURLString: "https://example/new.jpg"
        )
        check.equal("known artwork survives enrichment", enriched.first?.artworkURLString, "https://example/old.jpg")
        check.equal("non-empty titles still update", enriched.first?.title, "Better Title")
    }

    check.suite("Queue and device decoding") {
        // Engine queue snapshots carry current-track identity and unfiltered protocol
        // rows. Swift projects the upcoming rail and catalog supplies labels.
        let queueJSON = """
            {"track":{"uri":"spotify:track:now","provider":"context","uid":"occ-now"},
             "protocol_next_tracks":[
              {"uri":"spotify:track:next1","provider":"queue","uid":"q0"},
              {"uri":"spotify:delimiter","provider":"delimiter","uid":""},
              {"uri":"spotify:track:autoplay","provider":"autoplay","uid":""}]}
            """
        do {
            let decoded = try JSONDecoder().decode(RustQueueState.self, from: Data(queueJSON.utf8))
            check.equal("current track keeps identity", decoded.track?.uri, "spotify:track:now")
            let upcoming = QueueProtocolProjection.upcomingEntries(
                from: (decoded.protocolNextTracks ?? []).map { $0.domainTrack() }
            )
            check.equal("upcoming projection keeps providers", upcoming.first?.provider, "queue")
            check.equal("delimiter is hidden from the upcoming rail", upcoming.count, 1)
            check.equal("protocol transport keeps delimiter and autoplay", decoded.protocolNextTracks?.count, 3)
        } catch {
            check.check("queue state decodes: \(error)", false)
        }
        let pausedPlaybackJSON = """
            {"is_playing":true,"is_paused":true,"track_uri":"spotify:track:abc",
             "position_ms":42000,"duration_ms":180000,"timestamp_ms":1000000}
            """
        do {
            let state = try JSONDecoder().decode(RustPlaybackState.self, from: Data(pausedPlaybackJSON.utf8))
            check.check("remote paused bit decodes", state.isPlaying && state.isPaused)
            check.equal("remote snapshot timestamp decodes", state.timestampMS, 1_000_000)
        } catch {
            check.check("playback state decodes: \(error)", false)
        }

        let devicesJSON = """
            [{"id":"abc123","name":"Living Room","type":"speaker","is_active":false,
              "is_private_session":false,"is_restricted":false,"volume_percent":40,"disable_volume":false},
             {"id":"def456","name":"Mac","type":"Computer","is_active":true,
              "is_private_session":false,"is_restricted":false,"volume_percent":null,"disable_volume":false}]
            """
        do {
            let devices = try JSONDecoder().decode([ConnectDevice].self, from: Data(devicesJSON.utf8))
            check.equal("device list decodes", devices.count, 2)
            check.equal("active device is named", devices.first(where: \.isActive)?.name, "Mac")
            check.equal("type maps to an icon", devices.first?.symbolName, "hifispeaker")
        } catch {
            check.check("devices decode: \(error)", false)
        }

        // Spotify spells device types in mixed case; icon lookup must not.
        let casedTypesJSON = """
            [{"id":"t1","name":"Den","type":"TV","is_active":false},
             {"id":"t2","name":"Phone","type":"SMARTPHONE","is_active":false}]
            """
        do {
            let cased = try JSONDecoder().decode([ConnectDevice].self, from: Data(casedTypesJSON.utf8))
            check.equal("tv type maps regardless of case", cased.first?.symbolName, "tv")
            check.equal("phone type maps regardless of case", cased.last?.symbolName, "iphone")
        } catch {
            check.check("cased device types decode: \(error)", false)
        }
    }

    check.suite("Queue provider labels") {
        // What fed a row, in listener-facing words.
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
        check.equal(
            "local device is identified even while inactive", local.displayName(localDeviceID: "local"),
            "Aural (This Mac)")
        check.equal(
            "active remote device is identified as playing", remote.displayName(localDeviceID: "local"),
            "Phone (Playing)")
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
                devices: [
                    local,
                    ConnectDevice(
                        id: "phone",
                        name: "Phone",
                        type: "smartphone",
                        isActive: false
                    ),
                ],
                fallbackRemoteDeviceID: "phone"
            ),
            .remote(from: "local", to: "phone")
        )
    }

    check.suite("Documented queue response") {
        let json = """
            {"currently_playing":null,"queue":[
              {"id":"track-id","uri":"spotify:track:track-id","name":"First Track",
               "duration_ms":123000,"artists":[{"name":"First Artist"}],
               "album":{"name":"First Album","images":[
                 {"url":"https://example.com/small.jpg","width":64,"height":64},
                 {"url":"https://example.com/large.jpg","width":640,"height":640}
               ]}},
              {"id":"episode-id","uri":"spotify:episode:episode-id","name":"An Episode",
               "duration_ms":456000,"show":{"name":"A Show","publisher":"A Publisher","images":[]}}
            ]}
            """
        do {
            let tracks = try SpotifyWebPlayerAPI.decodeQueue(Data(json.utf8))
            check.equal(
                "documented queue preserves order", tracks.map(\.uri),
                [
                    "spotify:track:track-id", "spotify:episode:episode-id",
                ])
            check.equal("queue track decodes its artist", tracks.first?.artist, "First Artist")
            check.equal("queue track decodes its album", tracks.first?.album, "First Album")
            check.equal(
                "queue track chooses the largest artwork",
                tracks.first?.artworkURL?.absoluteString,
                "https://example.com/large.jpg"
            )
            check.equal("queue episode decodes its publisher", tracks.last?.artist, "A Publisher")
        } catch {
            check.check("documented queue decodes: \(error)", false)
        }
    }

    check.suite("Connect command encoding") {
        do {
            let encoded = try JSONEncoder().encode(SpotifyConnectCommand.seek(to: 12_345))
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            check.equal("seek endpoint is encoded", object?["endpoint"] as? String, "seek_to")
            check.equal("seek position is encoded", object?["value"] as? Int, 12_345)

            let shuffle = try JSONEncoder().encode(SpotifyConnectCommand.shuffle(true))
            let shuffleObject = try JSONSerialization.jsonObject(with: shuffle) as? [String: Any]
            check.equal("shuffle boolean is encoded", shuffleObject?["value"] as? Bool, true)

            let add = try JSONEncoder().encode(SpotifyConnectCommand.addToQueue("spotify:track:abc"))
            let addObject = try JSONSerialization.jsonObject(with: add) as? [String: Any]
            let track = addObject?["track"] as? [String: Any]
            check.equal("queue endpoint is encoded", addObject?["endpoint"] as? String, "add_to_queue")
            check.equal("queued track uri is encoded", track?["uri"] as? String, "spotify:track:abc")
            check.nil_("add_to_queue does not encode next_tracks", addObject?["next_tracks"])

            let setQueue = try JSONEncoder().encode(
                SpotifyConnectCommand.setQueue(
                    next: [QueueProtocolTrack(uri: "spotify:track:keep", uid: "q0", provider: "queue")],
                    prev: [QueueProtocolTrack(uri: "spotify:track:prev", uid: "p0", provider: "context")],
                    queueRevision: "rev-1"
                )
            )
            let setObject = try JSONSerialization.jsonObject(with: setQueue) as? [String: Any]
            check.equal("set_queue endpoint is encoded", setObject?["endpoint"] as? String, "set_queue")
            check.equal(
                "set_queue preserves prev_tracks",
                ((setObject?["prev_tracks"] as? [[String: Any]])?.first?["uri"] as? String),
                "spotify:track:prev"
            )
        } catch {
            check.check("Connect commands encode: \(error)", false)
        }
    }
}
