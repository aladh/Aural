import SwiftUI

/// Small, bounded color vocabulary for catalog media surfaces.
///
/// System colors remain the default for text, separators, selection, and window materials. The
/// fixed media green is reserved for actions and the current-track indicator, so it never becomes
/// a second global accent or selection system.
enum AuralPalette {
    static let mediaGreen = Color(red: 0.118, green: 0.843, blue: 0.376)
    // Spotify-familiar elevations: canvas, resting card, and hovered card.
    static let catalogCanvas = Color(red: 0.071, green: 0.071, blue: 0.071)
    static let mediaSurface = Color(red: 0.094, green: 0.094, blue: 0.094)
    static let mediaSurfaceHover = Color(red: 0.141, green: 0.141, blue: 0.141)
    static let quickAccessSurface = Color(red: 0.16, green: 0.16, blue: 0.16)
    static let quickAccessSurfaceHover = Color(red: 0.22, green: 0.22, blue: 0.22)
    // The player is a distinct, near-black anchor rather than another raised media card.
    static let playerShelf = Color(red: 0.035, green: 0.035, blue: 0.035)
    static let playerDivider = Color.white.opacity(0.10)
    static let playerPrimary = Color.white.opacity(0.92)
    static let playerSecondary = Color.white.opacity(0.62)
    static let remotePlaybackForeground = Color(red: 0.025, green: 0.12, blue: 0.06)

    static func mediaCardSurface(isHovering: Bool) -> Color {
        isHovering ? mediaSurfaceHover : .clear
    }

    static let artworkPlaceholderColors = [
        Color.secondary.opacity(0.13),
        Color.primary.opacity(0.08),
    ]
}
