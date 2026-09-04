import SwiftUI

/// Restrained near-black catalog canvas that keeps artwork and native selection as visual anchors.
struct CatalogCanvasBackground: View {
    var body: some View {
        SpottyPalette.catalogCanvas
            .ignoresSafeArea()
    }
}

/// A low-contrast boundary between an artwork-led header and its native table.
struct CatalogTableDivider: View {
    var body: some View {
        Rectangle()
            .fill(.separator.opacity(0.5))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A compact, unambiguous primary action for artwork-led detail headers.
struct CircularPlayButton: View {
    let action: () -> Void
    let isEnabled: Bool

    init(action: @escaping () -> Void, isEnabled: Bool = true) {
        self.action = action
        self.isEnabled = isEnabled
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.black)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(SpottyPalette.mediaGreen)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
        .help("Play")
        .accessibilityLabel("Play")
    }
}
