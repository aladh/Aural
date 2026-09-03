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
                "the persistent player uses a neutral opaque shelf",
                palette.contains("static let playerShelf")
                    && playerBar.contains(".fill(AuralPalette.playerShelf)")
                    && !playerBar.contains(".fill(.bar)")
            )
            runner.check(
                "primary transport and resting progress remain neutral",
                playerComponents.contains("player.canTogglePlayback ? Color.primary")
                    && playerComponents.contains("isHovering ? AuralPalette.mediaGreen : Color.primary")
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
