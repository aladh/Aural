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

        runner.noThrow("Home and player style sources are readable") {
            let home = try visualStyleSourceFile("Aural/Views/HomeView.swift")
            let palette = try visualStyleSourceFile("Aural/Views/AuralPalette.swift")
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
                "the persistent player uses a compact near-black shelf",
                palette.contains(
                    "static let playerShelf = Color(red: 0.035, green: 0.035, blue: 0.035)"
                )
                    && palette.contains("static let playerPrimary = Color.primary.opacity(0.92)")
                    && palette.contains("static let playerSecondary = Color.secondary.opacity(0.92)")
                    && playerBar.contains(".fill(AuralPalette.playerShelf)")
                    && playerBar.contains("player.hasCurrentTrack ? 64 : 60")
                    && playerBar.contains(".frame(minWidth: 500, maxWidth: 520)")
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
                visualStyleOccurrenceCount("Button {", in: trailingControls) == 1
                    && visualStyleOccurrenceCount("devicesMenu", in: trailingControls) == 2
                    && visualStyleOccurrenceCount("Image(systemName:", in: trailingControls) == 1
                    && trailingControls.contains("Image(systemName: \"list.bullet\")")
                    && !trailingControls.contains("Toggle")
                    && !trailingControls.contains("Slider")
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
