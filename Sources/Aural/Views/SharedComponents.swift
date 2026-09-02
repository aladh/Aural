import AppKit
import AuralDomain
import SwiftUI

/// Catalog playlist writes available to track tables without Pathfinder DTOs.
struct TrackPlaylistActions {
    let editablePlaylists: [CatalogItem]
    let canRemoveOccurrences: Bool
    let addToPlaylist: @MainActor (CatalogItem, [CatalogTrack]) -> Void
    let removeOccurrences: @MainActor ([String]) -> Void
}

enum CatalogLayout {
    static let contentPadding: CGFloat = 28
    static let headerThreshold: CGFloat = 640
    static let headerMinimumArtwork: CGFloat = 184
    static let headerMaximumArtwork: CGFloat = 236
    static let cardArtwork: CGFloat = 160
    static let cardPadding: CGFloat = 8
    static let cardCornerRadius: CGFloat = 11
    static let cardWidth: CGFloat = cardArtwork
    static let gridMinimumWidth: CGFloat = cardArtwork + (cardPadding * 2)
    static let gridMaximumWidth: CGFloat = 208
    static let gridSpacing: CGFloat = 16
}

/// The content canvas follows the system appearance while borrowing Spotify's quiet,
/// near-black detail-pane hierarchy in Dark Mode. The accent wash is intentionally subtle so
/// artwork and selection remain the visual anchors.
struct CatalogCanvasBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .underPageBackgroundColor)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.11 : 0.045),
                    Color.accentColor.opacity(colorScheme == .dark ? 0.025 : 0.01),
                    .clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 320)
        }
        .ignoresSafeArea()
    }
}

/// A low-contrast boundary between an artwork-led header and its native table.
struct CatalogTableDivider: View {
    var body: some View {
        Rectangle()
            .fill(.separator.opacity(0.72))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A compact, unambiguous primary action for artwork-led detail headers.
struct CircularPlayButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 17, weight: .bold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(.accentColor)
        .help("Play")
        .accessibilityLabel("Play")
    }
}

enum MediaGridLayout {
    static var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: CatalogLayout.gridMinimumWidth, maximum: CatalogLayout.gridMaximumWidth),
                spacing: CatalogLayout.gridSpacing
            )
        ]
    }
}

/// Shared artwork-led identity for albums, artists, and playlists.
struct MediaDetailHeader: View {
    let item: CatalogItem
    let description: String
    let detail: String
    let itemCount: String?
    let canPlay: Bool
    let play: () -> Void

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
        GeometryReader { proxy in
            if proxy.size.width >= CatalogLayout.headerThreshold {
                horizontalHeader(width: proxy.size.width)
            } else {
                compactHeader(width: proxy.size.width)
            }
        }
        .frame(minHeight: 272, maxHeight: 320)
        .background { CatalogHeaderWash() }
        .padding(.horizontal, CatalogLayout.contentPadding)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private func horizontalHeader(width: CGFloat) -> some View {
        let artworkSize = min(
            max(width * 0.24, CatalogLayout.headerMinimumArtwork),
            CatalogLayout.headerMaximumArtwork
        )

        return HStack(alignment: .bottom, spacing: 26) {
            artwork(size: artworkSize)
            detailColumn(titleSize: min(max(38, artworkSize * 0.2), 46))
            Spacer(minLength: 0)
        }
    }

    private func compactHeader(width: CGFloat) -> some View {
        let artworkSize = min(max(width * 0.3, 152), CatalogLayout.headerMinimumArtwork)

        return HStack(alignment: .bottom, spacing: 20) {
            artwork(size: artworkSize)
            detailColumn(titleSize: 36)
        }
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
    private func detailColumn(titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.kind.rawValue.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.8)

            Text(item.title)
                .font(.system(size: titleSize, weight: .bold))
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

            CircularPlayButton(action: play)
                .disabled(!canPlay)
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

private struct CatalogHeaderWash: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.075 : 0.03),
                    .clear,
                ],
                center: .topLeading,
                startRadius: 10,
                endRadius: 430
            )
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.035 : 0.012),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }
}

/// A native macOS table shared by playlists, search results, and track libraries.
/// Single-click selects; command-click extends a simple multi-selection; double-click
/// or Return plays the primary row, matching desktop table behavior.
struct TrackTable: View {
    let tracks: CatalogTrackCollection
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    var showsDateAdded = false
    var playlistActions: TrackPlaylistActions?
    @State private var selection: Set<CatalogTrack.ID> = []
    @State private var sortOrder: [KeyPathComparator<TrackTableRow>] = []
    @State private var displayCache: TrackTableDisplayCache

    init(
        tracks: CatalogTrackCollection,
        metadata: CatalogMetadataRepository,
        playback: CatalogPlaybackAccess,
        showsDateAdded: Bool = false,
        playlistActions: TrackPlaylistActions? = nil
    ) {
        self.tracks = tracks
        self.metadata = metadata
        self.playback = playback
        self.showsDateAdded = showsDateAdded
        self.playlistActions = playlistActions
        _displayCache = State(
            initialValue: TrackTableDisplayCache(
                tracks,
                sortValues: metadata.trackTableSortValues,
                sortValuesRevision: metadata.trackAttributesRevision
            )
        )
    }

    var body: some View {
        Table(displayCache.rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { row in
                titleCell(row.track)
            }
            .width(min: 152, ideal: 224, max: 264)

            TableColumn("Artist", value: \.artist) { row in
                Text(row.track.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 96, ideal: 124, max: 160)

            TableColumn("Album", value: \.album) { row in
                Text(row.track.album).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 96, ideal: 132, max: 170)

            TableColumn("Popularity", value: \.popularitySortValue) { row in
                Text(attributeText(metadata.trackAttributes[row.track.uri]?.popularity.map(String.init)))
                    .foregroundStyle(.tertiary)
            }
            .width(64)

            TableColumn("BPM", value: \.bpmSortValue) { row in
                Text(attributeText(metadata.trackAttributes[row.track.uri]?.bpm.map(String.init)))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Tempo in beats per minute")
            }
            .width(44)

            TableColumn("Key", value: \.keySortValue) { row in
                Text(attributeText(metadata.trackAttributes[row.track.uri]?.key))
                    .foregroundStyle(.tertiary)
            }
            .width(38)

            if showsDateAdded {
                TableColumn("Date Added", value: \.dateAddedSortValue) { row in
                    Text(formatDateAdded(row.track.addedAt))
                        .foregroundStyle(.secondary)
                }
                .width(90)
            }

            TableColumn("Time", value: \.duration) { row in
                Text(formatDuration(row.track.duration))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .width(44)
        }
        .contextMenu(forSelectionType: CatalogTrack.ID.self) { selectedIDs in
            let selectedTracks = PlaylistMutationSelection.orderedTracks(
                selectedIDs: selectedIDs,
                in: displayCache.rows.map(\.track)
            )
            if selectedTracks.count == 1, let track = selectedTracks.first {
                Button("Play", systemImage: "play.fill") {
                    play(track)
                }
                .disabled(!playback.canStartPlayback)
            }

            if !selectedTracks.isEmpty {
                Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    playback.addToQueue(QueueMutationSelection.addURIs(from: selectedTracks))
                }
                .disabled(!playback.canStartPlayback)
            }

            if !selectedTracks.isEmpty, let playlistActions {
                Menu("Add to Playlist") {
                    if playlistActions.editablePlaylists.isEmpty {
                        Button("No Editable Playlists") {}
                            .disabled(true)
                    } else {
                        ForEach(playlistActions.editablePlaylists) { playlist in
                            Button(playlist.title) {
                                playlistActions.addToPlaylist(playlist, selectedTracks)
                            }
                        }
                    }
                }
                .accessibilityLabel("Add to Playlist")

                if playlistActions.canRemoveOccurrences {
                    Divider()
                    Button("Remove from Playlist", role: .destructive) {
                        playlistActions.removeOccurrences(
                            PlaylistMutationSelection.occurrenceIDsForRemoval(from: selectedTracks)
                        )
                    }
                    .disabled(
                        PlaylistMutationSelection.occurrenceIDsForRemoval(from: selectedTracks).isEmpty
                    )
                }
            }
        } primaryAction: { selectedIDs in
            let selectedTracks = PlaylistMutationSelection.orderedTracks(
                selectedIDs: selectedIDs,
                in: displayCache.rows.map(\.track)
            )
            guard selectedTracks.count == 1, let track = selectedTracks.first else { return }
            play(track)
        }
        .onDeleteCommandIfAvailable(playlistActions?.canRemoveOccurrences == true) {
            removeSelectedOccurrences()
        }
        .accessibilityLabel("Tracks")
        .font(.callout)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .onChange(of: displayInputs, initial: true) { oldInputs, newInputs in
            _ = displayCache.update(
                tracks,
                sortValues: metadata.trackTableSortValues,
                sortValuesRevision: metadata.trackAttributesRevision,
                sortOrder: newInputs.sortOrder
            )
            if oldInputs.version != newInputs.version {
                selection = TrackTableDisplayCache.prunedSelection(selection, from: tracks.tracks)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private var displayInputs: TrackTableDisplayInputs {
        TrackTableDisplayInputs(
            version: tracks.version,
            sortValuesRevision: sortOrder.usesTrackAttributes ? metadata.trackAttributesRevision : 0,
            sortOrder: sortOrder
        )
    }

    private func isCurrent(_ track: CatalogTrack) -> Bool {
        playback.hasCurrentTrack && playback.currentTrackURI == track.uri
    }

    private func titleCell(_ track: CatalogTrack) -> some View {
        HStack(spacing: 6) {
            if isCurrent(track) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Current track")
            }
            Text(track.title)
                .fontWeight(.medium)
                .foregroundStyle(isCurrent(track) ? Color.accentColor : .primary)
                .lineLimit(1)
        }
    }

    private func play(_ track: CatalogTrack) {
        guard playback.canStartPlayback else { return }
        playback.playTrack(track)
    }

    private func removeSelectedOccurrences() {
        guard playlistActions?.canRemoveOccurrences == true else { return }
        let selectedTracks = PlaylistMutationSelection.orderedTracks(
            selectedIDs: selection,
            in: displayCache.rows.map(\.track)
        )
        let uids = PlaylistMutationSelection.occurrenceIDsForRemoval(from: selectedTracks)
        guard !uids.isEmpty else { return }
        playlistActions?.removeOccurrences(uids)
    }

}

private struct TrackTableDisplayInputs: Equatable {
    var version: UUID
    var sortValuesRevision: UInt64
    var sortOrder: [KeyPathComparator<TrackTableRow>]
}

private extension View {
    @ViewBuilder
    func onDeleteCommandIfAvailable(_ enabled: Bool, perform action: @escaping () -> Void) -> some View {
        if enabled {
            onDeleteCommand(perform: action)
        } else {
            self
        }
    }
}

/// Column placeholder for track details that have not loaded.
private func attributeText(_ value: String?) -> String {
    value ?? "—"
}

struct RemoteArtwork: View {
    let url: URL?
    let kind: CatalogItem.Kind
    let cornerRadius: CGFloat
    let pointSize: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.28))
        }
        .accessibilityHidden(true)
        .task(id: cacheKey) {
            await loadImage()
        }
        // List rows retain their SwiftUI state after recycling. Releasing this strong reference
        // lets the bounded NSCache actually evict artwork during long scrolling sessions.
        .onDisappear { image = nil }
    }

    private var cacheKey: String { "\(url?.absoluteString ?? "")#\(pointSize)" }

    private func loadImage() async {
        image = nil
        guard let url else { return }
        let decoded = await ArtworkCache.shared.image(for: url, pointSize: pointSize)
        // Cancellation does not stop the shared fetch from answering; the row
        // must not adopt what an earlier identity asked for.
        guard !Task.isCancelled else { return }
        image = decoded
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.secondary.opacity(0.13), Color.accentColor.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch kind {
        case .album: "square.stack.fill"
        case .artist: "music.mic"
        case .playlist: "music.note.list"
        case .track: "music.note"
        case .unknown: "waveform"
        }
    }
}

struct LoadingState: View {
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var actionSystemImage: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(action: action) {
                    if let actionSystemImage {
                        Label(actionTitle, systemImage: actionSystemImage)
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

func formatDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}

func formatDateAdded(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .omitted) ?? "—"
}
