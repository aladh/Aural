import AppKit
import AuralDomain
import SwiftUI

/// A native macOS table shared by playlists, search results, and track libraries.
/// Single-click selects; double-click or Return plays, matching desktop table behavior.
struct TrackTable: View {
    let tracks: [CatalogTrack]
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    var showsDateAdded = false
    @State private var selection: CatalogTrack.ID?
    @State private var sortOrder: [KeyPathComparator<CatalogTrack>] = []
    @State private var displayedTracks: [CatalogTrack]

    init(
        tracks: [CatalogTrack],
        metadata: CatalogMetadataRepository,
        playback: CatalogPlaybackAccess,
        showsDateAdded: Bool = false
    ) {
        self.tracks = tracks
        self.metadata = metadata
        self.playback = playback
        self.showsDateAdded = showsDateAdded
        _displayedTracks = State(initialValue: tracks)
    }

    var body: some View {
        Table(displayedTracks, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \CatalogTrack.title) { track in
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
            .width(min: 160, ideal: 240, max: 280)

            TableColumn("Artist", value: \CatalogTrack.artist) { track in
                Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 100, ideal: 130, max: 170)

            TableColumn("Album", value: \CatalogTrack.album) { track in
                Text(track.album).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 100, ideal: 140, max: 180)

            TableColumn("Popularity") { track in
                Text(attributeText(metadata.trackAttributes[track.uri]?.popularity.map(String.init)))
                    .foregroundStyle(.tertiary)
            }
            .width(68)

            TableColumn("BPM") { track in
                Text(attributeText(metadata.trackAttributes[track.uri]?.bpm.map(String.init)))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Tempo in beats per minute")
            }
            .width(46)

            TableColumn("Key") { track in
                Text(attributeText(metadata.trackAttributes[track.uri]?.key))
                    .foregroundStyle(.tertiary)
            }
            .width(40)

            if showsDateAdded {
                TableColumn("Date Added", value: \CatalogTrack.dateAddedSortValue) { track in
                    Text(formatDateAdded(track.addedAt))
                        .foregroundStyle(.secondary)
                }
                .width(96)
            }

            TableColumn("Time") { track in
                Text(formatDuration(track.duration))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .width(46)
        }
        .contextMenu(forSelectionType: CatalogTrack.ID.self) { selectedIDs in
            if let track = selectedTrack(in: selectedIDs) {
                Button("Play", systemImage: "play.fill") {
                    play(track)
                }
                .disabled(!playback.canStartPlayback)

                Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    playback.addToQueue(track.uri)
                }
                .disabled(!playback.canStartPlayback)
            }
        } primaryAction: { selectedIDs in
            guard let track = selectedTrack(in: selectedIDs) else { return }
            play(track)
        }
        .accessibilityLabel("Tracks")
        .onChange(of: tracks, initial: true) { _, _ in
            updateDisplayedTracks()
        }
        .onChange(of: sortOrder) { _, _ in
            updateDisplayedTracks()
        }
    }

    private func isCurrent(_ track: CatalogTrack) -> Bool {
        playback.hasCurrentTrack && playback.currentTrackURI == track.uri
    }

    private func selectedTrack(in selectedIDs: Set<CatalogTrack.ID>) -> CatalogTrack? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return tracks.first { $0.id == id }
    }

    private func play(_ track: CatalogTrack) {
        guard playback.canStartPlayback else { return }
        playback.playTrack(track)
    }

    private func updateDisplayedTracks() {
        displayedTracks = sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder)
    }
}

private extension CatalogTrack {
    /// A nonoptional key gives SwiftUI's native Table header a sortable date column.
    var dateAddedSortValue: Date { addedAt ?? .distantPast }
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
