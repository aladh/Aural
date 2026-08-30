import Foundation

func runCatalogPlaybackAccessSourceContractChecks(_ check: CheckRunner) {
    check.suite("CatalogPlaybackAccess source contract") {
        let snapshottingInit = """
        struct CatalogPlaybackAccess {
            init(player: PlaybackStore) {
                isConnected = player.isConnected
                accountEpoch = player.state.accountEpoch
                self.player = player
            }
        }
        """
        check.equal(
            "a snapshotting initializer is reported",
            CatalogPlaybackAccessSourceContract.significantLines(
                in: CatalogPlaybackAccessSourceContract.initializerBody(in: snapshottingInit)
            ),
            [
                "isConnected = player.isConnected",
                "accountEpoch = player.state.accountEpoch",
                "self.player = player",
            ]
        )

        check.equal(
            "a store-only initializer matches the allowed assignments",
            CatalogPlaybackAccessSourceContract.significantLines(
                in: CatalogPlaybackAccessSourceContract.initializerBody(
                    in: """
                    init(player: PlaybackStore) {
                        self.player = player
                        self.playerIdentity = ObjectIdentifier(player)
                    }
                    """
                )
            ),
            CatalogPlaybackAccessSourceContract.allowedInitializerLines
        )

        check.equal(
            "stored action closures are reported",
            CatalogPlaybackAccessSourceContract.storedActionClosureLines(
                in: "    let connect: @MainActor () -> Void\n    let playURI: () -> Void"
            ),
            [
                "let connect: @MainActor () -> Void",
                "let playURI: () -> Void",
            ]
        )
        check.equal(
            "methods are not stored action closures",
            CatalogPlaybackAccessSourceContract.storedActionClosureLines(
                in: "    func connect() {\n        player.connect()\n    }"
            ),
            []
        )

        check.check(
            "player identity equality is recognized",
            CatalogPlaybackAccessSourceContract.equatesByPlayerIdentity(
                "    nonisolated static func == (lhs: CatalogPlaybackAccess, rhs: CatalogPlaybackAccess) -> Bool {\n        lhs.playerIdentity == rhs.playerIdentity\n    }"
            )
        )
        check.check(
            "unrelated equality is not player identity",
            !CatalogPlaybackAccessSourceContract.equatesByPlayerIdentity(
                "    static func == (lhs: CatalogPlaybackAccess, rhs: CatalogPlaybackAccess) -> Bool { true }"
            )
        )

        check.equal(
            "a store-only RootView accessor matches the allowed construction",
            CatalogPlaybackAccessSourceContract.significantLines(
                in: CatalogPlaybackAccessSourceContract.catalogPlaybackAccessorBody(
                    in: """
                        private var catalogPlayback: CatalogPlaybackAccess {
                            CatalogPlaybackAccess(player: player)
                        }
                    """
                )
            ),
            CatalogPlaybackAccessSourceContract.allowedRootAccessorLines
        )
        check.notEqual(
            "a snapshotting RootView accessor is reported",
            CatalogPlaybackAccessSourceContract.significantLines(
                in: CatalogPlaybackAccessSourceContract.catalogPlaybackAccessorBody(
                    in: """
                        private var catalogPlayback: CatalogPlaybackAccess {
                            CatalogPlaybackAccess(player: player, isConnected: player.isConnected)
                        }
                    """
                )
            ),
            CatalogPlaybackAccessSourceContract.allowedRootAccessorLines
        )

        check.noThrow("production catalog playback sources are readable") {
            let sources = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Aural")
            let access = try String(
                contentsOf: sources.appending(path: "CatalogPlaybackAccess.swift"),
                encoding: .utf8
            )
            let root = try String(
                contentsOf: sources.appending(path: "RootView.swift"),
                encoding: .utf8
            )
            let table = try String(
                contentsOf: sources.appending(path: "Views/SharedComponents.swift"),
                encoding: .utf8
            )
            let playlist = try String(
                contentsOf: sources.appending(path: "Views/PlaylistDetailView.swift"),
                encoding: .utf8
            )
            let media = try String(
                contentsOf: sources.appending(path: "Views/MediaDetailViews.swift"),
                encoding: .utf8
            )
            let library = try String(
                contentsOf: sources.appending(path: "Views/LibraryViews.swift"),
                encoding: .utf8
            )
            let home = try String(
                contentsOf: sources.appending(path: "Views/HomeView.swift"),
                encoding: .utf8
            )

            check.equal(
                "production initializer only stores the player",
                CatalogPlaybackAccessSourceContract.significantLines(
                    in: CatalogPlaybackAccessSourceContract.initializerBody(in: access)
                ),
                CatalogPlaybackAccessSourceContract.allowedInitializerLines
            )
            check.equal(
                "production access stores no per-body action closures",
                CatalogPlaybackAccessSourceContract.storedActionClosureLines(in: access),
                []
            )
            check.check(
                "production access equates by player identity",
                CatalogPlaybackAccessSourceContract.equatesByPlayerIdentity(access)
            )
            check.equal(
                "RootView catalogPlayback only constructs access from the scene player",
                CatalogPlaybackAccessSourceContract.significantLines(
                    in: CatalogPlaybackAccessSourceContract.catalogPlaybackAccessorBody(in: root)
                ),
                CatalogPlaybackAccessSourceContract.allowedRootAccessorLines
            )
            check.check(
                "TrackTable highlights from hasCurrentTrack and currentTrackURI",
                table.contains("playback.hasCurrentTrack && playback.currentTrackURI == track.uri")
            )
            check.check(
                "TrackTable play and queue respect canStartPlayback",
                table.contains(".disabled(!playback.canStartPlayback)")
                    && table.contains("playback.playTrack(track)")
                    && table.contains("playback.addToQueue(")
            )
            check.check(
                "playlist detail still keys its load task on account epoch and connection",
                playlist.contains("accountEpoch: playback.accountEpoch")
                    && playlist.contains("isConnected: playback.isConnected")
                    && playlist.contains("guard playback.isConnected else { return }")
            )
            check.check(
                "playlist detail still uses status copy and connect",
                playlist.contains("Text(playback.statusText)")
                    && playlist.contains("playback.connect()")
                    && playlist.contains("playback.playPlaylist(item)")
            )
            check.check(
                "album and artist loads still key on account epoch",
                media.contains("accountEpoch: playback.accountEpoch")
                    && media.contains("isConnected: playback.isConnected")
                    && media.contains("playback.playURI(item.uri)")
            )
            check.check(
                "search and library still observe connection for empty and load states",
                library.contains("if !playback.isConnected")
                    && library.contains("playback.connect()")
                    && library.contains(".task(id: playback.accountEpoch)")
                    && home.contains("else if !playback.isConnected")
            )
            check.check(
                "liked songs keep account-epoch loading in RootView",
                root.contains(".task(id: catalogPlayback.accountEpoch)")
                    && root.contains("guard catalogPlayback.isConnected else { return }")
            )
        }
    }
}
