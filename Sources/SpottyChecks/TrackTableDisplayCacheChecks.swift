import SpottyDomain
import Foundation

func runTrackTableDisplayCacheChecks(_ check: CheckRunner) {
    func track(
        id: String,
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        addedAt: Date? = nil
    ) -> CatalogTrack {
        CatalogTrack(
            id: id,
            uri: "spotify:track:\(id)",
            title: title,
            artist: artist,
            album: album,
            duration: 1,
            artworkURL: nil,
            addedAt: addedAt
        )
    }

    check.suite("Catalog track collection version") {
        var collection = CatalogTrackCollection()
        let initialVersion = collection.version

        collection.replace([track(id: "a", title: "A"), track(id: "b", title: "B")])
        check.check("first replace mints a new version", collection.version != initialVersion)
        check.equal("replace publishes the new rows", collection.tracks.map(\.id), ["a", "b"])

        let afterFirstReplace = collection.version
        collection.replace(collection.tracks)
        check.check("equal content still mints a new version", collection.version != afterFirstReplace)

        var copy = collection
        check.equal("a copy keeps the current version until it replaces", copy.version, collection.version)
        copy.replace([track(id: "c", title: "C")])
        check.check("copy-and-replace mints a version the original does not share", copy.version != collection.version)
        check.equal("the original rows stay on the unreplaced copy", collection.tracks.map(\.id), ["a", "b"])

        let seeded = CatalogTrackCollection(tracks: [track(id: "seed", title: "Seed")])
        check.check("seeded construction mints its own version", seeded.version != collection.version)
        check.check(
            "two fresh owners mint distinct versions",
            CatalogTrackCollection().version != CatalogTrackCollection().version)
    }

    check.suite("Track table display cache") {
        let alpha = track(id: "alpha", title: "Alpha", artist: "B", album: "Z")
        let beta = track(id: "beta", title: "Beta", artist: "A", album: "Y")
        let gamma = track(id: "gamma", title: "Gamma", artist: "A", album: "X")
        let source = [gamma, alpha, beta]

        var collection = CatalogTrackCollection()
        collection.replace(source)
        var cache = TrackTableDisplayCache(collection)
        check.equal("empty sort keeps source order", cache.rows.map(\.id), ["gamma", "alpha", "beta"])

        let snapshot = collection
        collection.replace([gamma, track(id: "middle", title: "Replaced"), beta])
        check.check("the unreplaced copy is a cache hit", !cache.update(snapshot, sortOrder: []))
        check.equal(
            "a cache hit keeps the previous rows",
            cache.rows.map(\.id),
            ["gamma", "alpha", "beta"]
        )
        check.check("replace of the live collection recomputes", cache.update(collection, sortOrder: []))
        check.equal(
            "rows follow the replaced generation",
            cache.rows.map(\.id),
            ["gamma", "middle", "beta"]
        )

        collection.replace(source)
        _ = cache.update(collection, sortOrder: [])
        let titleAscending = [KeyPathComparator(\TrackTableRow.title)]
        check.check("sort-field change recomputes", cache.update(collection, sortOrder: titleAscending))
        check.equal("title ascending uses the native comparator", cache.rows.map(\.id), ["alpha", "beta", "gamma"])

        let titleDescending = [
            KeyPathComparator(\TrackTableRow.title, order: .reverse)
        ]
        check.check("descending recomputes", cache.update(collection, sortOrder: titleDescending))
        check.equal("title descending reverses the column", cache.rows.map(\.id), ["gamma", "beta", "alpha"])

        let artistThenReverseTitle = [
            KeyPathComparator(\TrackTableRow.artist),
            KeyPathComparator(\TrackTableRow.title, order: .reverse),
        ]
        check.check("multi-comparator recomputes", cache.update(collection, sortOrder: artistThenReverseTitle))
        check.equal(
            "artist then reverse title keeps comparator order",
            cache.rows.map(\.id),
            ["gamma", "beta", "alpha"]
        )

        check.check(
            "attribute revision is ignored for a title sort",
            !cache.update(
                collection,
                sortValuesRevision: 1,
                sortOrder: artistThenReverseTitle
            )
        )

        let popularityAscending = [KeyPathComparator(\TrackTableRow.popularitySortValue)]
        let initialPopularity = [
            alpha.uri: TrackTableSortValues(popularity: 80, bpm: nil, key: nil),
            beta.uri: TrackTableSortValues(popularity: 20, bpm: nil, key: nil),
        ]
        check.check(
            "attribute-backed sort recomputes",
            cache.update(
                collection,
                sortValues: initialPopularity,
                sortValuesRevision: 1,
                sortOrder: popularityAscending
            )
        )
        check.equal(
            "missing popularity follows present values",
            cache.rows.map(\.id),
            ["beta", "alpha", "gamma"]
        )
        let refreshedPopularity = [
            alpha.uri: TrackTableSortValues(popularity: 10, bpm: nil, key: nil),
            beta.uri: TrackTableSortValues(popularity: 90, bpm: nil, key: nil),
            gamma.uri: TrackTableSortValues(popularity: 50, bpm: nil, key: nil),
        ]
        check.check(
            "new attribute revision re-sorts an active attribute column",
            cache.update(
                collection,
                sortValues: refreshedPopularity,
                sortValuesRevision: 2,
                sortOrder: popularityAscending
            )
        )
        check.equal(
            "attribute arrival updates the active order",
            cache.rows.map(\.id),
            ["alpha", "gamma", "beta"]
        )
        check.check(
            "unchanged attribute revision is a cache hit",
            !cache.update(
                collection,
                sortValues: initialPopularity,
                sortValuesRevision: 2,
                sortOrder: popularityAscending
            )
        )

        var other = CatalogTrackCollection()
        other.replace([beta])
        check.check(
            "a different collection recomputes",
            cache.update(other, sortOrder: [])
        )
        check.equal("rows follow the new collection", cache.rows.map(\.id), ["beta"])

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        var dated = CatalogTrackCollection()
        dated.replace([
            track(id: "undated", title: "Undated", addedAt: nil),
            track(id: "old", title: "Old", addedAt: older),
            track(id: "new", title: "New", addedAt: newer),
        ])
        var dateCache = TrackTableDisplayCache(dated)
        check.check(
            "date-added sort recomputes",
            dateCache.update(dated, sortOrder: [KeyPathComparator(\TrackTableRow.dateAddedSortValue)])
        )
        check.equal(
            "nil dates sink below present dates for the table column",
            dateCache.rows.map(\.id),
            ["old", "new", "undated"]
        )
        check.check(
            "the playlist's recently-added projection is newest first",
            dateCache.update(
                dated,
                sortOrder: [KeyPathComparator(\TrackTableRow.dateAddedSortValue, order: .reverse)]
            )
        )
        check.equal(
            "newest date-added rows precede older rows",
            dateCache.rows.map(\.id),
            ["new", "old", "undated"]
        )
        check.equal(
            "playlist source positions stay attached after sorting",
            dateCache.rows.map(\.sourceIndex),
            [2, 1, 0]
        )
        check.equal(
            "sorted playlist rows receive one-based display positions",
            dateCache.rows.map { dateCache.displayPosition(for: $0) },
            [1, 2, 3]
        )
        check.equal(
            "display positions map back to source occurrences",
            dateCache.rows.reduce(into: [Int: Int]()) { positions, row in
                positions[row.sourceIndex] = dateCache.displayPosition(for: row)
            },
            [2: 1, 1: 2, 0: 3]
        )
        check.check("clearing the projection restores source order", dateCache.update(dated, sortOrder: []))
        check.equal(
            "the source collection remains oldest-to-newest",
            dated.tracks.map(\.id),
            ["undated", "old", "new"]
        )
        check.equal(
            "clearing sorting restores the source order",
            dateCache.rows.map(\.id),
            ["undated", "old", "new"]
        )
        check.equal(
            "clearing sorting restores playlist source positions",
            dateCache.rows.map(\.sourceIndex),
            [0, 1, 2]
        )
        check.equal(
            "clearing sorting restores one-based display positions",
            dateCache.rows.map { dateCache.displayPosition(for: $0) },
            [1, 2, 3]
        )

        let first = track(id: "uid-a", title: "Zebra")
        let second = CatalogTrack(
            id: "uid-b",
            uri: first.uri,
            title: "Alpha",
            artist: first.artist,
            album: first.album,
            duration: first.duration,
            artworkURL: nil,
            addedAt: nil
        )
        var duplicates = CatalogTrackCollection()
        duplicates.replace([first, second])
        var duplicateCache = TrackTableDisplayCache(duplicates)
        _ = duplicateCache.update(duplicates, sortOrder: titleAscending)
        check.equal(
            "duplicate occurrences keep distinct identities after sort",
            duplicateCache.rows.map(\.id),
            ["uid-b", "uid-a"]
        )

        let tiedSecond = CatalogTrack(
            id: "uid-c",
            uri: first.uri,
            title: first.title,
            artist: first.artist,
            album: first.album,
            duration: first.duration,
            artworkURL: nil,
            addedAt: nil
        )
        duplicates.replace([first, tiedSecond])
        _ = duplicateCache.update(duplicates, sortOrder: titleAscending)
        check.equal(
            "equal duplicate occurrences keep source order",
            duplicateCache.rows.map(\.id),
            ["uid-a", "uid-c"]
        )

        var replacement = CatalogTrackCollection()
        replacement.replace([alpha, beta, gamma])
        var replacementCache = TrackTableDisplayCache(replacement)
        var forked = replacement
        forked.replace([alpha, track(id: "beta-2", title: "Omega"), gamma])
        check.check(
            "copy-and-replace of a same-count middle row recomputes",
            replacementCache.update(forked, sortOrder: titleAscending)
        )
        check.equal(
            "middle replacement participates in the new sort",
            replacementCache.rows.map(\.id),
            ["alpha", "gamma", "beta-2"]
        )
        check.check(
            "the unreplaced original is still a distinct version",
            forked.version != replacement.version
        )

        let selection: Set<String> = ["alpha", "gone", "gamma"]
        check.equal(
            "selection pruning drops identities that left the authoritative collection",
            TrackTableDisplayCache.prunedSelection(selection, from: forked.tracks),
            ["alpha", "gamma"]
        )
        check.equal(
            "empty selection stays empty",
            TrackTableDisplayCache.prunedSelection([], from: forked.tracks),
            []
        )
    }
}
