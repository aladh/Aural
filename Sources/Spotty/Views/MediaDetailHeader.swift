import SpottyDomain
import SwiftUI

/// Shared artwork-led identity for albums, artists, and playlists.
struct MediaDetailHeader: View {
    let item: CatalogItem
    let description: String
    let detail: String
    let itemCount: String?
    let canPlay: Bool
    let play: () -> Void
    @State private var availableWidth: CGFloat = 0

    init(
        item: CatalogItem,
        description: String = "",
        detail: String = "",
        itemCount: String? = nil,
        canPlay: Bool,
        play: @escaping () -> Void
    ) {
        self.item = item
        self.description = description
        self.detail = detail
        self.itemCount = itemCount
        self.canPlay = canPlay
        self.play = play
    }

    var body: some View {
        headerContent(width: availableWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                guard newWidth > 0 else { return }
                availableWidth = newWidth
            }
            .padding(.horizontal, CatalogLayout.contentPadding)
            .padding(.top, 20)
            .padding(.bottom, 16)
    }

    @ViewBuilder
    private func headerContent(width: CGFloat) -> some View {
        if width >= CatalogLayout.headerThreshold {
            horizontalHeader(width: width)
        } else {
            compactHeader(width: width)
        }
    }

    private func horizontalHeader(width: CGFloat) -> some View {
        return HStack(alignment: .bottom, spacing: 26) {
            artwork(size: horizontalArtworkSize(for: width))
            detailColumn()
            Spacer(minLength: 0)
        }
    }

    private func compactHeader(width: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                artwork(size: compactArtworkSize(for: width))
                detailColumn()
            }

            VStack(alignment: .leading, spacing: 18) {
                artwork(size: compactArtworkSize(for: width))
                detailColumn()
            }
        }
    }

    private func horizontalArtworkSize(for width: CGFloat) -> CGFloat {
        switch width {
        case ..<820:
            return CatalogLayout.headerMinimumArtwork
        case ..<940:
            return CatalogLayout.headerMediumArtwork
        default:
            return CatalogLayout.headerMaximumArtwork
        }
    }

    private func compactArtworkSize(for width: CGFloat) -> CGFloat {
        width < 560 ? CatalogLayout.headerCompactArtwork : CatalogLayout.headerMinimumArtwork
    }

    private func artwork(size: CGFloat) -> some View {
        RemoteArtwork(
            url: item.artworkURL,
            kind: item.kind,
            cornerRadius: item.kind == .artist ? size / 2 : 10,
            pointSize: size
        )
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.24), radius: 14, y: 7)
    }

    @ViewBuilder
    private func detailColumn() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.kind.rawValue.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.8)

            Text(item.title)
                .font(.largeTitle.bold())
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)

            if !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !supportingText.isEmpty {
                Text(supportingText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            CircularPlayButton(action: play, isEnabled: canPlay)
                .accessibilityHint("Starts this \(item.kind.rawValue.lowercased())")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    private var supportingText: String {
        [item.subtitle, detail, itemCount ?? ""]
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(item.kind.rawValue) != .orderedSame }
            .joined(separator: " · ")
    }
}
