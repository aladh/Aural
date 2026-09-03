import AuralDomain
import Foundation
@testable import AuralCore

@MainActor
func runVisualStyleContractChecks(_ runner: CheckRunner) {
    runner.suite("Spotify-familiar visual hierarchy contract") {
        runner.equal("the leading Home section is quick access", homeSectionPresentation(at: 0), .quickAccess)
        runner.equal("the second Home section stays a shelf", homeSectionPresentation(at: 1), .shelf)
        runner.equal("later Home sections stay shelves", homeSectionPresentation(at: 8), .shelf)

        let remote = PlaybackDevice(id: "speaker", name: "Kitchen", type: "speaker", isActive: true)
        let local = PlaybackDevice(id: "mac", name: "This Mac", type: "computer", isActive: true)
        let confirmed = remotePlaybackBannerPresentation(
            phase: .ready,
            owner: .remote(remote),
            hasCurrentTrack: true,
            isPlaying: true
        )
        runner.equal("confirmed remote playback names its device", confirmed?.device.name, "Kitchen")
        runner.equal("confirmed remote playback carries transport state", confirmed?.isPlaying, true)
        runner.equal(
            "confirmed paused remote playback remains visible",
            remotePlaybackBannerPresentation(
                phase: .ready,
                owner: .remote(remote),
                hasCurrentTrack: true,
                isPlaying: false
            )?.isPlaying,
            false
        )
        runner.nil_(
            "an uncertain remembered route does not claim remote playback",
            remotePlaybackBannerPresentation(
                phase: .ready,
                owner: .uncertain(remote),
                hasCurrentTrack: true,
                isPlaying: false
            )
        )
        runner.nil_(
            "an unidentified uncertain owner has no remote banner",
            remotePlaybackBannerPresentation(
                phase: .ready,
                owner: .uncertain(nil),
                hasCurrentTrack: true,
                isPlaying: false
            )
        )
        runner.nil_(
            "local playback has no remote banner",
            remotePlaybackBannerPresentation(
                phase: .ready,
                owner: .local(local),
                hasCurrentTrack: true,
                isPlaying: true
            )
        )
        runner.nil_(
            "remote ownership without a current track has no banner",
            remotePlaybackBannerPresentation(
                phase: .ready,
                owner: .remote(remote),
                hasCurrentTrack: false,
                isPlaying: false
            )
        )
        runner.nil_(
            "recovering playback does not make a stale remote claim",
            remotePlaybackBannerPresentation(
                phase: .recovering,
                owner: .remote(remote),
                hasCurrentTrack: true,
                isPlaying: true
            )
        )

        runner.noThrow("Home, playlist, and player style sources are readable") {
            let home = try visualStyleSourceFile("Aural/Views/HomeView.swift")
            let palette = try visualStyleSourceFile("Aural/Views/AuralPalette.swift")
            let playlistDetail = try visualStyleSourceFile("Aural/Views/PlaylistDetailView.swift")
            let table = try visualStyleSourceFile("Aural/Views/SharedComponents.swift")
            let catalogPlaybackAccess = try visualStyleSourceFile("Aural/CatalogPlaybackAccess.swift")
            let playlistTableColumns = try visualStyleSourceSection(
                table,
                from: "            if variant == .playlist {",
                through: "            } else {"
            )
            let playlistTitleCell = try visualStyleSourceSection(
                table,
                from: "    private func playlistTitleCell",
                through: "    private func titleCell"
            )
            let playerBar = try visualStyleSourceFile("Aural/Views/NowPlayingBar.swift")
            let playerComponents = try visualStyleSourceFile("Aural/Views/NowPlayingComponents.swift")
            let trailingControls = try visualStyleSourceSection(
                playerComponents,
                from: "struct NowPlayingTimeControls: View",
                through: "    private var devicesMenu: some View"
            )
            let deviceControl = try visualStyleSourceSection(
                playerComponents,
                from: "    private var devicesMenu: some View",
                through: "    private func deviceName"
            )

            runner.check(
                "Home leads with a bounded compact shortcut shelf",
                home.contains("QuickAccessShelf(section: section")
                    && home.contains("switch homeSectionPresentation(at: index)")
                    && !home.contains("localizedCaseInsensitiveContains")
                    && home.contains("section.items.prefix(8)")
                    && home.contains(".adaptive(minimum: 220, maximum: 340)")
            )
            runner.check(
                "media cards are flat until hover",
                palette.contains("isHovering ? mediaSurfaceHover : .clear")
            )
            runner.check(
                "playlist details keep a dedicated compact hero and action strip",
                playlistDetail.contains("PlaylistDetailHero(")
                    && playlistDetail.contains("PlaylistDetailActionStrip")
                    && playlistDetail.contains("pointSize: size")
                    && playlistDetail.contains("LinearGradient(")
                    && playlistDetail.contains("AuralPalette.playlistHeroGradient")
                    && palette.contains("static let playlistHeroGradient")
                    && !playlistDetail.contains("MediaDetailHeader(")
            )
            runner.check(
                "playlist metadata stays truthful and duration is explicit",
                playlistDetail.contains("store.description")
                    && playlistDetail.contains("ownerText")
                    && playlistDetail.contains("songCountText")
                    && playlistDetail.contains("formatPlaylistDuration(totalDuration)")
                    && playlistDetail.contains("item.subtitle")
            )
            runner.check(
                "playlist tables start with a local newest-date projection",
                playlistDetail.contains("variant: .playlist")
                    && table.contains("let initialSortOrder = variant.initialSortOrder")
                    && table.contains("case .playlist:")
                    && table.contains("sortOrder: initialSortOrder")
            )
            runner.check(
                "playlist tables match Spotify's compact column structure",
                playlistDetail.contains("variant: .playlist")
                    && table.contains("enum TrackTableVariant")
                    && playlistTableColumns.contains("TableColumn(\"#\")")
                    && playlistTableColumns.contains("playlistIndexCell(row)")
                    && playlistTableColumns.contains("playlistTitleCell(row.track)")
                    && playlistTableColumns.contains("TableColumn(\"Album\", value: \\.album)")
                    && playlistTableColumns.contains("TableColumn(\"Date Added\", value: \\.dateAddedSortValue)")
                    && playlistTableColumns.contains("TableColumn(\"Duration\", value: \\.duration)")
                    && !playlistTableColumns.contains("TableColumn(\"Artist\"")
                    && !playlistTableColumns.contains("TableColumn(\"Popularity\"")
                    && !playlistTableColumns.contains("TableColumn(\"BPM\"")
                    && !playlistTableColumns.contains("TableColumn(\"Key\"")
                    && playlistTitleCell.contains("RemoteArtwork(")
            )
            runner.check(
                "playlist table rows use cached display positions and semantic current-track labels",
                table.contains("displayCache.displayPosition(for: row)")
                    && table.contains("speaker.wave.2.fill")
                    && table.contains("if isCurrentTrack && playback.isPlaying")
                    && catalogPlaybackAccess.contains("var isPlaying: Bool { player.isPlaying }")
                    && table.contains("playlistRowMinimumHeight")
                    && table.contains("Current track, track \\(position) of \\(total)")
                    && table.contains("formatCatalogDuration(row.track.duration)")
                    && playlistTitleCell.contains("kind: .track")
                    && playlistTitleCell.contains("pointSize: 30")
            )
            runner.check(
                "playlist hero title is a responsive accessibility heading",
                playlistDetail.contains("return 64")
                    && playlistDetail.contains("case ..<840:")
                    && playlistDetail.contains("accessibilityAddTraits(.isHeader)")
                    && playlistDetail.contains("horizontalPadding")
            )
            runner.check(
                "playlist actions keep one green circular play control",
                playlistDetail.contains("CircularPlayButton(action: play, isEnabled: canPlay)")
                    && table.contains("struct CircularPlayButton")
                    && table.contains(".buttonBorderShape(.circle)")
                    && table.contains(".opacity(isEnabled ? 1 : 0.45)")
                    && table.contains(".disabled(!isEnabled)")
                    && table.contains(".help(\"Play\")")
                    && !playlistDetail.contains("PlaylistPlayButton")
            )
            runner.check(
                "playlist source order has a native accessible restore path",
                table.contains(".toolbar {")
                    && table.contains("Button(\"Restore Playlist Order\", systemImage: \"arrow.uturn.backward\")")
                    && table.contains("sortOrder = []")
                    && table.contains(".disabled(sortOrder.isEmpty)")
                    && table.contains(".accessibilityHint(\"Show tracks in the playlist's saved order\")")
            )
            runner.check(
                "the persistent player uses a compact near-black shelf",
                palette.contains(
                    "static let playerShelf = Color(red: 0.035, green: 0.035, blue: 0.035)"
                )
                    && palette.contains("static let playerPrimary = Color.primary.opacity(0.92)")
                    && palette.contains("static let playerSecondary = Color.secondary.opacity(0.92)")
                    && palette.contains("static let playerDivider = Color.primary.opacity(0.10)")
                    && playerBar.contains(".fill(AuralPalette.playerShelf)")
                    && playerBar.contains(".frame(width: 44, alignment: alignment)")
                    && playerBar.contains(".minimumScaleFactor(0.7)")
                    && !playerBar.contains(".fill(.bar)")
            )
            runner.check(
                "primary transport and resting progress remain neutral",
                playerComponents.contains("player.canTogglePlayback ? AuralPalette.playerPrimary")
                    && playerComponents.contains("isHovering ? AuralPalette.mediaGreen : AuralPalette.playerPrimary")
            )
            runner.check(
                "the trailing player controls stay limited to queue and devices",
                visualStyleControlDeclarationCount(in: trailingControls) == 1
                    && visualStyleOccurrenceCount("Button {", in: trailingControls) == 1
                    && visualStyleOccurrenceCount("devicesMenu", in: trailingControls) == 2
                    && visualStyleOccurrenceCount("Image(systemName:", in: trailingControls) == 1
                    && trailingControls.contains("Image(systemName: \"list.bullet\")")
                    && visualStyleOccurrenceCount("Menu {", in: deviceControl) == 1
                    && visualStyleOccurrenceCount("Image(systemName:", in: deviceControl) == 1
                    && deviceControl.contains("Image(systemName: \"display.2\")")
                    && deviceControl.contains(
                        "player.isActiveDevice ? AuralPalette.mediaGreen : AuralPalette.playerSecondary"
                    )
            )
            runner.check(
                "identified remote playback gets a Spotify-familiar green footer",
                playerBar.contains("if let banner = player.remotePlaybackBanner")
                    && playerBar.contains("RemotePlaybackBanner(device: banner.device, isPlaying: banner.isPlaying)")
                    && playerBar.contains(".background(AuralPalette.mediaGreen)")
                    && playerBar.contains("Playing\" : \"Paused")
                    && playerBar.contains("reduceMotion ? nil : .snappy")
                    && palette.contains("static let remotePlaybackForeground")
            )
        }
    }
}

private func visualStyleSourceFile(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
}

private func visualStyleSourceSection(_ source: String, from start: String, through end: String) throws -> String {
    guard let startRange = source.range(of: start),
        let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
    else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return String(source[startRange.lowerBound..<endRange.upperBound])
}

private func visualStyleOccurrenceCount(_ token: String, in source: String) -> Int {
    source.components(separatedBy: token).count - 1
}

private func visualStyleControlDeclarationCount(in source: String) -> Int {
    [
        "Button {", "Button(",
        "Link {", "Link(",
        "Menu {", "Menu(",
        "Toggle {", "Toggle(",
        "Slider(",
        "Picker {", "Picker(",
    ].reduce(0) { $0 + visualStyleOccurrenceCount($1, in: source) }
}
