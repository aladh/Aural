import Foundation
@testable import AuralCore

@MainActor
func runVisualStyleContractChecks(_ runner: CheckRunner) {
    runner.suite("Spotify-familiar visual hierarchy contract") {
        runner.noThrow("Home and player style sources are readable") {
            let home = try visualStyleSourceFile("Aural/Views/HomeView.swift")
            let palette = try visualStyleSourceFile("Aural/Views/AuralPalette.swift")
            let playerBar = try visualStyleSourceFile("Aural/Views/NowPlayingBar.swift")
            let playerComponents = try visualStyleSourceFile("Aural/Views/NowPlayingComponents.swift")

            runner.check(
                "Home leads with a bounded compact shortcut shelf",
                home.contains("QuickAccessShelf(section: section")
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
