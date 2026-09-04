import AppKit
import AuralDomain
import Foundation
import SwiftUI
@testable import AuralCore

@MainActor
func runVisualContrastChecks(_ runner: CheckRunner) {
    runner.suite("Data-column and progress-rail contrast against their canvases") {
        runner.check(
            "data column text clears WCAG AA normal-text contrast on the catalog canvas",
            contrastRatio(AuralPalette.dataText, AuralPalette.catalogCanvas) >= 4.5
        )
        runner.check(
            "the unfilled progress rail clears WCAG AA non-text contrast on the player shelf",
            contrastRatio(AuralPalette.progressTrack, AuralPalette.playerShelf) >= 3.0
        )
        runner.check(
            "remote playback footer text clears WCAG AA normal-text contrast on the media green banner",
            contrastRatio(AuralPalette.remotePlaybackForeground, AuralPalette.mediaGreen) >= 4.5
        )
    }
}

/// WCAG 2.x contrast ratio between two colors, computed from their real sRGB components
/// rather than from source text, so a decorative or system color cannot slip past the gate.
private func contrastRatio(_ foreground: Color, _ background: Color) -> Double {
    let foregroundLuminance = relativeLuminance(of: foreground)
    let backgroundLuminance = relativeLuminance(of: background)
    let lighter = max(foregroundLuminance, backgroundLuminance)
    let darker = min(foregroundLuminance, backgroundLuminance)
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(of color: Color) -> Double {
    guard let sRGB = NSColor(color).usingColorSpace(.sRGB) else {
        preconditionFailure("Expected a color convertible to the sRGB color space")
    }
    let red = linearize(Double(sRGB.redComponent))
    let green = linearize(Double(sRGB.greenComponent))
    let blue = linearize(Double(sRGB.blueComponent))
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
}

private func linearize(_ channel: Double) -> Double {
    channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
}
