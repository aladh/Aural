import Testing
//
//  PlaybackPanelChecks.swift
//  Spotty
//

import Foundation
@testable import SpottyCore
import struct SpottyDomain.QueueProtocolTrack

@Test
@MainActor
func testPlaybackPanel() {
    do {
        let anchorDate = Date(timeIntervalSince1970: 1_000)
        #expect(
            (interpolatedPlaybackPosition(
                anchor: 40,
                anchoredAt: anchorDate,
                now: anchorDate.addingTimeInterval(0.25),
                isPlaying: true,
                duration: 200
            )) == (40.25), "playing advances between backend samples")
        #expect(
            (interpolatedPlaybackPosition(
                anchor: 40,
                anchoredAt: anchorDate,
                now: anchorDate.addingTimeInterval(10),
                isPlaying: false,
                duration: 200
            )) == (40), "paused position stays anchored")
        #expect(
            (interpolatedPlaybackPosition(
                anchor: 199.8,
                anchoredAt: anchorDate,
                now: anchorDate.addingTimeInterval(1),
                isPlaying: true,
                duration: 200
            )) == (200), "interpolation stops at track duration")
        #expect(
            (interpolatedPlaybackPosition(
                anchor: 40,
                anchoredAt: anchorDate,
                now: anchorDate.addingTimeInterval(-1),
                isPlaying: true,
                duration: 200
            )) == (40), "clock reversal cannot move the playhead backward")

        let receivedAt = Date(timeIntervalSince1970: 1_010)
        #expect(
            (playbackSnapshotPosition(
                positionMilliseconds: 40_000,
                durationMilliseconds: 200_000,
                timestampMilliseconds: 1_005_000,
                isPlaying: true,
                now: receivedAt
            )) == (45), "playing Connect snapshots compensate for their timestamp")
        #expect(
            (playbackSnapshotPosition(
                positionMilliseconds: 40_000,
                durationMilliseconds: 200_000,
                timestampMilliseconds: 1_005_000,
                isPlaying: false,
                now: receivedAt
            )) == (40), "paused Connect snapshots stay at their exact position")
    }

    // Cold-start resolution: backend queue/state events carry uris without names,
    // so the bar's metadata must come from the loaded catalog.
    do {
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
        #expect((liked?.title) == ("Liked One"), "liked list resolves")
        let searched = metadata.knownTrack(for: "spotify:track:searched")
        #expect(
            (searched?.artworkURL?.absoluteString) == ("https://example/s.jpg"), "search results resolve with artwork")

        let info = metadata.displayInfo(for: "spotify:track:pl")
        #expect((info.title) == ("Playlist One"), "display info resolves the title")

        let unknown = metadata.displayInfo(for: "spotify:track:deadbeef")
        #expect((unknown.title) == ("Unknown track"), "unknown uris still name something")
        #expect((unknown.artist) == ("deadbeef"), "unknown uris surface their id")

        let homePlaylist = CatalogItem(
            id: "home-playlist",
            uri: "spotify:playlist:home",
            title: "Home Playlist",
            subtitle: "Listener",
            artworkURL: nil,
            kind: .playlist
        )
        metadata.replaceItems([homePlaylist], from: .home)
        #expect(
            (metadata.knownItem(for: homePlaylist.uri)?.title) == ("Home Playlist"),
            "home item lookup stays lazy and resolves")

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
        #expect(
            (queueWaitingForOrdering != queueWithOrdering) == true,
            "launch-time queue ordering restarts metadata hydration")
        let queueAfterHydration = SidePanelQueueRefreshIdentity(
            isConnected: true,
            currentTrackURI: "spotify:track:current",
            connectOrderingVersion: queueWithOrdering.connectOrderingVersion
        )
        #expect((queueAfterHydration) == (queueWithOrdering), "queue hydration does not schedule a second refresh")
    }

    do {
        let cycle: [RepeatMode] = [.off, .context, .track, .off]
        for (before, after) in zip(cycle, cycle.dropFirst()) {
            #expect((before.next) == (after), "cycle \(before) → \(after)")
        }

        #expect(
            (RepeatMode.context.flags) == (RepeatFlags(context: true, track: false)), "backend flags for context repeat"
        )
        #expect(
            (RepeatMode.track.flags) == (RepeatFlags(context: false, track: true)), "backend flags for track repeat")
        #expect((RepeatMode.off.flags) == (RepeatFlags(context: false, track: false)), "backend flags for no repeat")
        // The two backend switches compose back into one mode.
        #expect((RepeatMode(context: true, track: false)) == (.context), "flags rebuild to context")
        #expect((RepeatMode(context: true, track: true)) == (.track), "track flag wins over context")
        #expect((RepeatMode(context: false, track: false)) == (.off), "flags rebuild to off")
    }

    do {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = PlaybackHistoryStore()
        store.notePlayed(uri: "spotify:track:a", title: "A", artist: "X", artworkURL: nil, playedAt: now)
        #expect((store.entries.first?.playedAt) == (now), "history store records the injected playedAt")
        store.notePlayed(
            uri: "spotify:track:a",
            title: "A",
            artist: "X",
            artworkURL: nil,
            playedAt: now.addingTimeInterval(60)
        )
        #expect((store.entries.count) == (1), "history store replay keeps a single row")
        #expect(
            (store.entries.first?.playedAt) == (now.addingTimeInterval(60)),
            "history store replay uses the later injected timestamp")

        var entries = PlaybackHistory.updated(
            [], afterPlaying: "spotify:track:a", title: "A", artist: "X", artworkURLString: nil, playedAt: now)
        #expect((entries.first?.uri) == ("spotify:track:a"), "newest entry lands first")

        // Replaying the same track moves it rather than duplicating it.
        entries = PlaybackHistory.updated(
            entries,
            afterPlaying: "spotify:track:a",
            title: "A",
            artist: "X",
            artworkURLString: nil,
            playedAt: now.addingTimeInterval(60)
        )
        #expect((entries.count) == (1), "replay does not duplicate")
        #expect((entries.first?.playedAt) == (now.addingTimeInterval(60)), "replay refreshes the timestamp")

        // Metadata arriving late fills the entry in.
        entries = PlaybackHistory.withMetadata(
            entries,
            for: "spotify:track:a",
            title: "Real Title",
            artist: "Real Artist",
            artworkURLString: "https://example/a.jpg"
        )
        #expect((entries.first?.title) == ("Real Title"), "late metadata fills the title")
        #expect((entries.first?.playedAt) == (now.addingTimeInterval(60)), "late metadata keeps other fields")

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
        #expect((entries.count) == (PlaybackHistory.cap), "history is capped")

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
        #expect((capped.count) == (PlaybackHistory.cap), "cap boundary stays at the cap")
        #expect((capped.first?.uri) == ("spotify:track:new"), "the new track lands on top")
        #expect((capped.last?.uri) == ("spotify:track:t1"), "exactly the oldest row falls off")

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
        #expect((lifted.first?.uri) == ("spotify:track:a"), "a buried replay moves to the front")
        #expect((lifted.count) == (3), "the lift does not duplicate")
        #expect((lifted.last?.uri) == ("spotify:track:b"), "the other rows keep their order")

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
        #expect((afterMiss) == (untouched), "metadata for an absent uri changes nothing")

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
        #expect((enriched.first?.artworkURLString) == ("https://example/old.jpg"), "known artwork survives enrichment")
        #expect((enriched.first?.title) == ("Better Title"), "non-empty titles still update")
    }

    do {
        // DTO-shape smoke: current-track identity is uri/provider/uid, not catalog labels.
        // Upcoming presentation lives in the QueueProtocolProjection domain suite; wire
        // coverage is Rust layout/callback/getter tests (`TST-QUE-001`).
        let decoded = RustQueueState(
            revision: 1,
            sessionGeneration: 1,
            track: RustQueueState.Item(
                uri: "spotify:track:now",
                provider: "context",
                uid: "occ-now"
            ),
            protocolNextTracks: [],
            protocolPrevTracks: [],
            queueRevision: "",
            disallowSetQueue: false,
            disallowRemovingFromNextTracks: false
        )
        #expect((decoded.track?.uri) == ("spotify:track:now"), "current track keeps identity")
        #expect((decoded.track?.provider) == ("context"), "current track keeps provider")
        #expect((decoded.track?.uid) == ("occ-now"), "current track keeps uid")

        let devicesJSON = """
            [{"id":"abc123","name":"Living Room","type":"speaker","is_active":false,
              "is_private_session":false,"is_restricted":false,"volume_percent":40,"disable_volume":false},
             {"id":"def456","name":"Mac","type":"Computer","is_active":true,
              "is_private_session":false,"is_restricted":false,"volume_percent":null,"disable_volume":false}]
            """
        do {
            let devices = try JSONDecoder().decode([ConnectDevice].self, from: Data(devicesJSON.utf8))
            #expect((devices.count) == (2), "device list decodes")
            #expect((devices.first(where: \.isActive)?.name) == ("Mac"), "active device is named")
            #expect((devices.first?.symbolName) == ("hifispeaker"), "type maps to an icon")
        } catch {
            #expect((false) == true, "devices decode: \(error)")
        }

        // Spotify spells device types in mixed case; icon lookup must not.
        let casedTypesJSON = """
            [{"id":"t1","name":"Den","type":"TV","is_active":false},
             {"id":"t2","name":"Phone","type":"SMARTPHONE","is_active":false}]
            """
        do {
            let cased = try JSONDecoder().decode([ConnectDevice].self, from: Data(casedTypesJSON.utf8))
            #expect((cased.first?.symbolName) == ("tv"), "tv type maps regardless of case")
            #expect((cased.last?.symbolName) == ("iphone"), "phone type maps regardless of case")
        } catch {
            #expect((false) == true, "cased device types decode: \(error)")
        }
    }

    do {
        // What fed a row, in listener-facing words.
        let queued = QueueEntry(uri: "spotify:track:a", provider: "queue")
        let suggested = QueueEntry(uri: "spotify:track:b", provider: "autoplay")
        let contextual = QueueEntry(uri: "spotify:track:c", provider: "context")
        let documented = QueueEntry(uri: "spotify:track:d", provider: "web-api")
        #expect(
            (queued.sourceLabel == "From your queue"
                && suggested.sourceLabel == "Suggested by Spotify"
                && contextual.sourceLabel == "From the current context"
                && documented.sourceLabel == "Up next") == true, "providers map to listener labels")
        let repeated = [
            QueueEntry(uri: "spotify:track:a", provider: "queue", occurrence: 0),
            QueueEntry(uri: "spotify:track:a", provider: "queue", occurrence: 1),
        ]
        #expect((repeated[0].id != repeated[1].id) == true, "duplicate queue tracks have distinct row identities")

    }

    do {
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
            #expect(
                (tracks.map(\.uri))
                    == ([
                        "spotify:track:track-id", "spotify:episode:episode-id",
                    ]), "documented queue preserves order")
            #expect((tracks.first?.artist) == ("First Artist"), "queue track decodes its artist")
            #expect((tracks.first?.album) == ("First Album"), "queue track decodes its album")
            #expect(
                (tracks.first?.artworkURL?.absoluteString) == ("https://example.com/large.jpg"),
                "queue track chooses the largest artwork")
            #expect((tracks.last?.artist) == ("A Publisher"), "queue episode decodes its publisher")
        } catch {
            #expect((false) == true, "documented queue decodes: \(error)")
        }
    }

    do {
        do {
            let encoded = try JSONEncoder().encode(SpotifyConnectCommand.seek(to: 12_345))
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            #expect((object?["endpoint"] as? String) == ("seek_to"), "seek endpoint is encoded")
            #expect((object?["value"] as? Int) == (12_345), "seek position is encoded")

            let shuffle = try JSONEncoder().encode(SpotifyConnectCommand.shuffle(true))
            let shuffleObject = try JSONSerialization.jsonObject(with: shuffle) as? [String: Any]
            #expect((shuffleObject?["value"] as? Bool) == (true), "shuffle boolean is encoded")

            let add = try JSONEncoder().encode(SpotifyConnectCommand.addToQueue("spotify:track:abc"))
            let addObject = try JSONSerialization.jsonObject(with: add) as? [String: Any]
            let track = addObject?["track"] as? [String: Any]
            #expect((addObject?["endpoint"] as? String) == ("add_to_queue"), "queue endpoint is encoded")
            #expect((track?["uri"] as? String) == ("spotify:track:abc"), "queued track uri is encoded")
            #expect((addObject?["next_tracks"]) == nil, "add_to_queue does not encode next_tracks")

            let setQueue = try JSONEncoder().encode(
                SpotifyConnectCommand.setQueue(
                    next: [QueueProtocolTrack(uri: "spotify:track:keep", uid: "q0", provider: "queue")],
                    prev: [QueueProtocolTrack(uri: "spotify:track:prev", uid: "p0", provider: "context")],
                    queueRevision: "rev-1"
                )
            )
            let setObject = try JSONSerialization.jsonObject(with: setQueue) as? [String: Any]
            #expect((setObject?["endpoint"] as? String) == ("set_queue"), "set_queue endpoint is encoded")
            #expect(
                (((setObject?["prev_tracks"] as? [[String: Any]])?.first?["uri"] as? String)) == ("spotify:track:prev"),
                "set_queue preserves prev_tracks")
        } catch {
            #expect((false) == true, "Connect commands encode: \(error)")
        }
    }
}
