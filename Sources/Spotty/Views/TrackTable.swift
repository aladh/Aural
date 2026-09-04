import SpottyDomain
import SwiftUI

enum TrackTableVariant: Equatable {
    case catalog
    case playlist

    var initialSortOrder: [KeyPathComparator<TrackTableRow>] {
        switch self {
        case .catalog:
            []
        case .playlist:
            [KeyPathComparator(\TrackTableRow.dateAddedSortValue, order: .reverse)]
        }
    }
}

/// A native macOS table shared by playlists, search results, and track libraries.
/// Single-click selects; command-click extends a simple multi-selection; double-click
/// or Return plays the primary row, matching desktop table behavior.
struct TrackTable: View {
    let tracks: CatalogTrackCollection
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    let variant: TrackTableVariant
    var playlistActions: TrackPlaylistActions?
    @State private var selection: Set<CatalogTrack.ID> = []
    @State private var sortOrder: [KeyPathComparator<TrackTableRow>] = []
    @State private var displayCache: TrackTableDisplayCache

    init(
        tracks: CatalogTrackCollection,
        metadata: CatalogMetadataRepository,
        playback: CatalogPlaybackAccess,
        variant: TrackTableVariant = .catalog,
        playlistActions: TrackPlaylistActions? = nil
    ) {
        self.tracks = tracks
        self.metadata = metadata
        self.playback = playback
        self.variant = variant
        self.playlistActions = playlistActions
        let initialSortOrder = variant.initialSortOrder
        _sortOrder = State(initialValue: initialSortOrder)
        _displayCache = State(
            initialValue: TrackTableDisplayCache(
                tracks,
                sortValues: metadata.trackTableSortValues,
                sortValuesRevision: metadata.trackAttributesRevision,
                sortOrder: initialSortOrder
            )
        )
    }

    var body: some View {
        Table(displayCache.rows, selection: $selection, sortOrder: $sortOrder) {
            if variant == .playlist {
                TableColumn("#") { row in
                    playlistIndexCell(row)
                }
                .width(40)

                TableColumn("Title", value: \.title) { row in
                    playlistTitleCell(row.track)
                }
                .width(min: 184, ideal: 300, max: 520)

                TableColumn("Album", value: \.album) { row in
                    Text(row.track.album)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minHeight: CatalogLayout.playlistRowMinimumHeight, alignment: .center)
                }
                .width(min: 120, ideal: 180, max: 260)

                TableColumn("Date Added", value: \.dateAddedSortValue) { row in
                    Text(formatDateAdded(row.track.addedAt))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: CatalogLayout.playlistRowMinimumHeight, alignment: .center)
                }
                .width(min: 100, ideal: 120, max: 160)

                TableColumn("Duration", value: \.duration) { row in
                    Text(formatCatalogDuration(row.track.duration))
                        .monospacedDigit()
                        .foregroundStyle(SpottyPalette.dataText)
                        .frame(minHeight: CatalogLayout.playlistRowMinimumHeight, alignment: .center)
                }
                .width(70)
            } else {
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
                        .foregroundStyle(SpottyPalette.dataText)
                }
                .width(64)

                TableColumn("BPM", value: \.bpmSortValue) { row in
                    let text = attributeText(metadata.trackAttributes[row.track.uri]?.bpm.map(String.init))
                    Text(text)
                        .monospacedDigit()
                        .foregroundStyle(SpottyPalette.dataText)
                        .accessibilityLabel("BPM")
                        .accessibilityValue(text)
                }
                .width(44)

                TableColumn("Key", value: \.keySortValue) { row in
                    Text(attributeText(metadata.trackAttributes[row.track.uri]?.key))
                        .foregroundStyle(SpottyPalette.dataText)
                }
                .width(38)

                TableColumn("Time", value: \.duration) { row in
                    Text(formatDuration(row.track.duration))
                        .monospacedDigit()
                        .foregroundStyle(SpottyPalette.dataText)
                }
                .width(44)
            }
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
        .toolbar {
            if variant == .playlist {
                ToolbarItem {
                    Button("Restore Playlist Order", systemImage: "arrow.uturn.backward") {
                        sortOrder = []
                    }
                    .disabled(sortOrder.isEmpty)
                    .help("Restore the playlist's saved order")
                    .accessibilityHint("Show tracks in the playlist's saved order")
                }
            }
        }
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

    private func playlistIndexCell(_ row: TrackTableRow) -> some View {
        let isCurrentTrack = isCurrent(row.track)
        let isSelected = selection.contains(row.id)
        let position = displayCache.displayPosition(for: row)
        let total = displayCache.rows.count
        let indexForeground: Color = isSelected ? .primary : SpottyPalette.mediaGreen

        return Group {
            if isCurrentTrack && playback.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(indexForeground)
                    .accessibilityLabel("Current track, track \(position) of \(total)")
            } else if isCurrentTrack {
                Text(String(position))
                    .monospacedDigit()
                    .foregroundStyle(indexForeground)
                    .accessibilityLabel("Current track, track \(position) of \(total)")
            } else {
                Text(String(position))
                    .monospacedDigit()
                    .foregroundStyle(SpottyPalette.dataText)
                    .accessibilityLabel("Track \(position) of \(total)")
            }
        }
        .frame(maxWidth: .infinity, minHeight: CatalogLayout.playlistRowMinimumHeight, alignment: .trailing)
    }

    private func playlistTitleCell(_ track: CatalogTrack) -> some View {
        let isCurrentTrack = isCurrent(track)
        let isSelected = selection.contains(track.id)
        let titleForeground: Color = isCurrentTrack && !isSelected ? SpottyPalette.mediaGreen : .primary
        let artistForeground: Color = isCurrentTrack && !isSelected ? SpottyPalette.mediaGreen : .secondary

        return HStack(alignment: .center, spacing: 10) {
            RemoteArtwork(
                url: track.artworkURL,
                kind: .track,
                cornerRadius: 4,
                pointSize: 30
            )
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .fontWeight(.medium)
                    .foregroundStyle(titleForeground)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(artistForeground)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: CatalogLayout.playlistRowMinimumHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func titleCell(_ track: CatalogTrack) -> some View {
        let isCurrentTrack = isCurrent(track)
        let isSelected = selection.contains(track.id)

        return HStack(spacing: 6) {
            if isCurrentTrack {
                if isSelected {
                    Image(systemName: "speaker.wave.2.fill")
                        .accessibilityLabel("Current track")
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(SpottyPalette.mediaGreen)
                        .accessibilityLabel("Current track")
                }
            }
            if isCurrentTrack && isSelected {
                Text(track.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
            } else {
                Text(track.title)
                    .fontWeight(.medium)
                    .foregroundStyle(isCurrentTrack ? SpottyPalette.mediaGreen : .primary)
                    .lineLimit(1)
            }
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
