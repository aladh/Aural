import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

@Suite("Visual Style Contract")
struct VisualStyleContractTests {
    @Test
    @MainActor
    func testVisualStyleContract() {
        do {
            #expect((homeSectionPresentation(at: 0)) == (.quickAccess), "the leading Home section is quick access")
            #expect((homeSectionPresentation(at: 1)) == (.shelf), "the second Home section stays a shelf")
            #expect((homeSectionPresentation(at: 8)) == (.shelf), "later Home sections stay shelves")

            let remote = PlaybackDevice(id: "speaker", name: "Kitchen", type: "speaker", isActive: true)
            let local = PlaybackDevice(id: "mac", name: "This Mac", type: "computer", isActive: true)
            let confirmed = remotePlaybackBannerPresentation(
                phase: .ready,
                owner: .remote(remote),
                hasCurrentTrack: true,
                isPlaying: true
            )
            #expect((confirmed?.device.name) == ("Kitchen"), "confirmed remote playback names its device")
            #expect((confirmed?.isPlaying) == (true), "confirmed remote playback carries transport state")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .ready,
                    owner: .remote(remote),
                    hasCurrentTrack: true,
                    isPlaying: false
                )?.isPlaying) == (false), "confirmed paused remote playback remains visible")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .ready,
                    owner: .uncertain(remote),
                    hasCurrentTrack: true,
                    isPlaying: false
                )) == nil, "an uncertain remembered route does not claim remote playback")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .ready,
                    owner: .uncertain(nil),
                    hasCurrentTrack: true,
                    isPlaying: false
                )) == nil, "an unidentified uncertain owner has no remote banner")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .ready,
                    owner: .local(local),
                    hasCurrentTrack: true,
                    isPlaying: true
                )) == nil, "local playback has no remote banner")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .ready,
                    owner: .remote(remote),
                    hasCurrentTrack: false,
                    isPlaying: false
                )) == nil, "remote ownership without a current track has no banner")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .recovering,
                    owner: .remote(remote),
                    hasCurrentTrack: true,
                    isPlaying: true
                )) == nil, "recovering playback does not make a stale remote claim")

            do {
                do {
                    let home = try visualStyleSourceFile("Spotty/Views/HomeView.swift")
                    let palette = try visualStyleSourceFile("Spotty/Views/SpottyPalette.swift")
                    let playlistDetail = try visualStyleSourceFile("Spotty/Views/PlaylistDetailView.swift")
                    let detailHeader = try visualStyleSourceFile("Spotty/Views/MediaDetailHeader.swift")
                    let interactionModifiers = try visualStyleSourceFile("Spotty/Views/InteractionModifiers.swift")
                    let sidePanel = try visualStyleSourceFile("Spotty/Views/SidePanelView.swift")
                    let table =
                        try visualStyleSourceFile("Spotty/Views/TrackTable.swift")
                        + visualStyleSourceFile("Spotty/Views/CatalogChrome.swift")
                    let catalogPlaybackAccess = try visualStyleSourceFile("Spotty/CatalogPlaybackAccess.swift")
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
                    let playerBar = try visualStyleSourceFile("Spotty/Views/NowPlayingBar.swift")
                    let playerComponents = try visualStyleSourceFile("Spotty/Views/NowPlayingComponents.swift")
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
                    let playlistActionStrip = try visualStyleSourceSection(
                        playlistDetail,
                        from: "MediaDetailHeader(",
                        through: "CatalogTableDivider()"
                    )

                    #expect(
                        (home.contains("QuickAccessShelf(section: section")
                            && home.contains("switch homeSectionPresentation(at: index)")
                            && !home.contains("localizedCaseInsensitiveContains")
                            && home.contains("section.items.prefix(8)")
                            && home.contains(".adaptive(minimum: 220, maximum: 340)")) == true,
                        "Home leads with a bounded compact shortcut shelf")
                    #expect(
                        (palette.contains("isHovering ? mediaSurfaceHover : .clear")) == true,
                        "media cards are flat until hover")
                    #expect(
                        (playlistDetail.contains("MediaDetailHeader(")
                            && playlistDetail.contains("style: .playlist")
                            && playlistActionStrip.contains("CircularPlayButton(")
                            && playlistActionStrip.contains("Spacer(minLength: 0)")
                            && detailHeader.contains("pointSize: size")
                            && detailHeader.contains("LinearGradient(")
                            && detailHeader.contains("SpottyPalette.playlistHeroGradient")
                            && palette.contains("static let playlistHeroGradient")
                            && !playlistDetail.contains("PlaylistDetailHero")) == true,
                        "playlist details use the shared styled header and a separate action strip")
                    #expect(
                        (playlistDetail.contains("store.description")
                            && playlistDetail.contains("songCountText")
                            && playlistDetail.contains("formatPlaylistDuration(totalDuration)")
                            && playlistDetail.contains("guard showsPlaylistMetadata else { return nil }")
                            && !playlistDetail.contains("ownerText")
                            && detailHeader.contains("[item.subtitle, detail, itemCount ?? \"\"]")) == true,
                        "playlist owner is shown once and authoritative count and duration stay explicit")
                    #expect(
                        (playlistDetail.contains("variant: .playlist")
                            && table.contains("let initialSortOrder = variant.initialSortOrder")
                            && table.contains("case .playlist:")
                            && table.contains("sortOrder: initialSortOrder")) == true,
                        "playlist tables start with a local newest-date projection")
                    #expect(
                        (playlistDetail.contains("variant: .playlist")
                            && table.contains("enum TrackTableVariant")
                            && playlistTableColumns.contains("TableColumn(\"#\")")
                            && playlistTableColumns.contains("playlistIndexCell(row)")
                            && playlistTableColumns.contains("playlistTitleCell(row.track)")
                            && playlistTableColumns.contains("TableColumn(\"Album\", value: \\.album)")
                            && playlistTableColumns.contains(
                                "TableColumn(\"Date Added\", value: \\.dateAddedSortValue)")
                            && playlistTableColumns.contains("TableColumn(\"Duration\", value: \\.duration)")
                            && !playlistTableColumns.contains("TableColumn(\"Artist\"")
                            && !playlistTableColumns.contains("TableColumn(\"Popularity\"")
                            && !playlistTableColumns.contains("TableColumn(\"BPM\"")
                            && !playlistTableColumns.contains("TableColumn(\"Key\"")
                            && playlistTitleCell.contains("RemoteArtwork(")) == true,
                        "playlist tables match Spotify's compact column structure")
                    #expect(
                        (table.contains("displayCache.displayPosition(for: row)")
                            && table.contains("speaker.wave.2.fill")
                            && table.contains("if isCurrentTrack && playback.isPlaying")
                            && catalogPlaybackAccess.contains("var isPlaying: Bool { player.isPlaying }")
                            && table.contains("playlistRowMinimumHeight")
                            && table.contains("Current track, track \\(position) of \\(total)")
                            && table.contains("formatCatalogDuration(row.track.duration)")
                            && playlistTitleCell.contains("kind: .track")
                            && playlistTitleCell.contains("pointSize: 30")) == true,
                        "playlist table rows use cached display positions and semantic current-track labels")
                    #expect(
                        (detailHeader.contains("default: 64")
                            && detailHeader.contains("case ..<840:")
                            && detailHeader.contains("accessibilityAddTraits(.isHeader)")
                            && detailHeader.contains("CatalogLayout.contentPadding")) == true,
                        "playlist hero title is a responsive accessibility heading")
                    #expect(
                        (playlistDetail.contains("CircularPlayButton(")
                            && table.contains("struct CircularPlayButton")
                            && table.contains(".buttonBorderShape(.circle)")
                            && !table.contains(".opacity(isEnabled ? 1 : 0.45)")
                            && table.contains(".disabled(!isEnabled)")
                            && table.contains(".help(\"Play\")")
                            && !playlistDetail.contains("PlaylistPlayButton")) == true,
                        "playlist actions keep one green circular play control")
                    #expect(
                        (table.contains(".toolbar {")
                            && table.contains(
                                "Button(\"Restore Playlist Order\", systemImage: \"arrow.uturn.backward\")")
                            && table.contains("sortOrder = []")
                            && table.contains(".disabled(sortOrder.isEmpty)")
                            && table.contains(".accessibilityHint(\"Show tracks in the playlist's saved order\")"))
                            == true,
                        "playlist source order has a native accessible restore path")
                    #expect(
                        (palette.contains(
                            "static let playerShelf = Color(red: 0.035, green: 0.035, blue: 0.035)"
                        )
                            && palette.contains("static let playerPrimary = Color.primary.opacity(0.92)")
                            && palette.contains("static let playerSecondary = Color.secondary.opacity(0.92)")
                            && palette.contains("static let playerDivider = Color.primary.opacity(0.10)")
                            && playerBar.contains(".fill(SpottyPalette.playerShelf)")
                            && playerBar.contains(".frame(width: 44, alignment: alignment)")
                            && playerBar.contains(".minimumScaleFactor(0.7)")
                            && !playerBar.contains(".fill(.bar)")) == true,
                        "the persistent player uses a compact near-black shelf")
                    #expect(
                        (playerComponents.contains("? SpottyPalette.playerPrimary")
                            && playerComponents.contains(": SpottyPalette.playerDisabledControl")
                            && playerComponents.contains(
                                "isHovering ? SpottyPalette.mediaGreen : SpottyPalette.playerPrimary"))
                            == true, "primary transport and resting progress remain neutral")
                    #expect(
                        (visualStyleControlDeclarationCount(in: trailingControls) == 1
                            && visualStyleOccurrenceCount("Button {", in: trailingControls) == 1
                            && visualStyleOccurrenceCount("devicesMenu", in: trailingControls) == 2
                            && visualStyleOccurrenceCount("Image(systemName:", in: trailingControls) == 1
                            && trailingControls.contains("Image(systemName: \"list.bullet\")")
                            && visualStyleOccurrenceCount("Menu {", in: deviceControl) == 1
                            && visualStyleOccurrenceCount("Image(systemName:", in: deviceControl) == 1
                            && deviceControl.contains("Image(systemName: \"display.2\")")
                            && deviceControl.contains(
                                "player.isActiveDevice ? SpottyPalette.mediaGreen : SpottyPalette.playerSecondary"
                            )) == true, "the trailing player controls stay limited to queue and devices")
                    #expect(
                        (playerBar.contains("if let banner = player.remotePlaybackBanner")
                            && playerBar.contains(
                                "RemotePlaybackBanner(device: banner.device, isPlaying: banner.isPlaying)")
                            && playerBar.contains(".background(SpottyPalette.mediaGreen)")
                            && playerBar.contains("Playing\" : \"Paused")
                            && playerBar.contains(".animationIfAllowed(")
                            && palette.contains("static let remotePlaybackForeground")) == true,
                        "identified remote playback gets a Spotify-familiar green footer")
                    #expect(
                        (home.contains(".hoverSurface(isHovering: $isHovering)")
                            && sidePanel.contains(".hoverSurface(isHovering: $isHovering)")
                            && interactionModifiers.contains("private struct HoverSurfaceModifier")
                            && interactionModifiers.contains(".onDisappear { isHovering = false }")) == true,
                        "hoverable catalog surfaces share one recyclable hover modifier")
                    #expect(
                        (table.contains(".accessibilityLabel(\"BPM\")")
                            && table.contains(".accessibilityValue(text)")
                            && sidePanel.contains(".accessibilityElement(children: .ignore)")
                            && sidePanel.contains(".accessibilityValue(\"Played \\(relativeTime)\")")) == true,
                        "data values and queue/history rows expose deterministic VoiceOver elements")
                    #expect(
                        (!playerBar.contains(".animation(")
                            && playerBar.contains(".animationIfAllowed(")
                            && playerComponents.contains("animationIfAllowed(")
                            && playerComponents.contains("if reduceMotion")
                            && interactionModifiers.contains("reduceMotion")) == true,
                        "player shelf motion consistently honors Reduce Motion")

                } catch {
                    Issue.record(
                        "\("Home, playlist, and player style sources are readable"): unexpected error \(error)")
                }
            }
        }
    }
}

private func visualStyleSourceFile(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent("Sources").appendingPathComponent(relativePath),
        encoding: .utf8
    )
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
