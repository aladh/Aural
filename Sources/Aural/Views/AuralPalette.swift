import AppKit
import SwiftUI

/// Small, bounded color vocabulary for catalog media surfaces.
///
/// System colors remain the default for text, separators, selection, and window materials. The
/// fixed media green is reserved for actions and the current-track indicator, so it never becomes
/// a second global accent or selection system.
enum AuralPalette {
    static let mediaGreen = Color(red: 0.118, green: 0.843, blue: 0.376)
    static let lightCatalogCanvas = Color(nsColor: .windowBackgroundColor)

    // Spotify-familiar dark elevations: canvas, resting card, and hovered card.
    static let darkCatalogCanvas = Color(red: 0.071, green: 0.071, blue: 0.071)
    static let darkMediaSurface = Color(red: 0.094, green: 0.094, blue: 0.094)
    static let darkMediaSurfaceHover = Color(red: 0.141, green: 0.141, blue: 0.141)

    static func catalogCanvas(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkCatalogCanvas : lightCatalogCanvas
    }

    static func mediaCardSurface(for colorScheme: ColorScheme, isHovering: Bool) -> Color {
        guard colorScheme == .dark else {
            return isHovering ? Color.primary.opacity(0.055) : .clear
        }
        return isHovering ? darkMediaSurfaceHover : darkMediaSurface
    }

    static let artworkPlaceholderColors = [
        Color.secondary.opacity(0.13),
        Color.primary.opacity(0.08),
    ]
}
