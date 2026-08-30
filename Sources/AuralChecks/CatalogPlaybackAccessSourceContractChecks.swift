import Foundation

func runCatalogPlaybackAccessSourceContractChecks(_ check: CheckRunner) {
    check.suite("CatalogPlaybackAccess source contract") {
        let snapshottingInit = """
        struct CatalogPlaybackAccess {
            init(player: PlaybackStore) {
                canStartPlayback = player.canStartPlayback
                currentTrackURI = player.trackURI
                statusText = player.statusText
                self.player = player
            }
        }
        """
        check.equal(
            "a snapshotting initializer is reported",
            CatalogPlaybackAccessSourceContract.factTokensRead(
                in: CatalogPlaybackAccessSourceContract.initializerBody(in: snapshottingInit)
            ),
            ["canStartPlayback", "trackURI", "statusText"]
        )

        let lazyInit = """
        struct CatalogPlaybackAccess {
            init(player: PlaybackStore) {
                self.player = player
            }

            var canStartPlayback: Bool { player.canStartPlayback }
            var statusText: String { player.statusText }
        }
        """
        check.equal(
            "computed facts outside init are not initializer reads",
            CatalogPlaybackAccessSourceContract.factTokensRead(
                in: CatalogPlaybackAccessSourceContract.initializerBody(in: lazyInit)
            ),
            []
        )

        check.equal(
            "stored action closures are reported",
            CatalogPlaybackAccessSourceContract.storedActionClosureLines(
                in: "    let connect: @MainActor () -> Void\n    let playURI: @MainActor (String) -> Void"
            ),
            [
                "let connect: @MainActor () -> Void",
                "let playURI: @MainActor (String) -> Void",
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
                "    static func == (lhs: CatalogPlaybackAccess, rhs: CatalogPlaybackAccess) -> Bool {\n        lhs.player === rhs.player\n    }"
            )
        )
        check.check(
            "unrelated equality is not player identity",
            !CatalogPlaybackAccessSourceContract.equatesByPlayerIdentity(
                "    static func == (lhs: CatalogPlaybackAccess, rhs: CatalogPlaybackAccess) -> Bool { true }"
            )
        )

        let rootAccessor = """
            private var catalogPlayback: CatalogPlaybackAccess {
                CatalogPlaybackAccess(player: player)
            }
        """
        check.equal(
            "a store-only RootView accessor is fact-lazy",
            CatalogPlaybackAccessSourceContract.factTokensRead(
                in: CatalogPlaybackAccessSourceContract.catalogPlaybackAccessorBody(in: rootAccessor)
            ),
            []
        )
        check.equal(
            "a snapshotting RootView accessor is reported",
            CatalogPlaybackAccessSourceContract.factTokensRead(
                in: CatalogPlaybackAccessSourceContract.catalogPlaybackAccessorBody(
                    in: """
                        private var catalogPlayback: CatalogPlaybackAccess {
                            CatalogPlaybackAccess(player: player, canStartPlayback: player.canStartPlayback)
                        }
                    """
                )
            ),
            ["canStartPlayback"]
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
            check.equal(
                "production initializer does not snapshot playback facts",
                CatalogPlaybackAccessSourceContract.factTokensRead(
                    in: CatalogPlaybackAccessSourceContract.initializerBody(in: access)
                ),
                []
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
                "RootView catalogPlayback construction is fact-lazy",
                CatalogPlaybackAccessSourceContract.factTokensRead(
                    in: CatalogPlaybackAccessSourceContract.catalogPlaybackAccessorBody(in: root)
                ),
                []
            )
            check.check(
                "RootView still constructs CatalogPlaybackAccess from the scene player",
                CatalogPlaybackAccessSourceContract.catalogPlaybackAccessorBody(in: root)
                    .contains("CatalogPlaybackAccess(player: player)")
            )
        }
    }
}
