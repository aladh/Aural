//
//  SidePanelView.swift
//  Aural
//
//  The right-hand playback panel: the play queue and the recently played list.
//

import AuralDomain
import SwiftUI

/// Restarts queue hydration when launch-time Connect ordering arrives after the account becomes
/// ready. Metadata-only repository updates deliberately do not change this identity, avoiding a
/// refresh loop while individual track names fill in.
struct SidePanelQueueRefreshIdentity: Equatable {
    let isConnected: Bool
    let currentTrackURI: String
    let queueURIs: [String]
}

struct SidePanelView: View {
    let metadata: CatalogMetadataRepository
    let player: PlaybackStore
    let onClose: () -> Void

    @State private var tab: Tab = .queue

    enum Tab: String, CaseIterable {
        case queue = "Queue"
        case history = "History"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch tab {
                case .queue:
                    queueList
                case .history:
                    historyList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: queueRefreshIdentity) {
            guard player.isConnected else { return }
            player.refreshQueue()
        }
        .onDisappear { player.cancelQueueRefresh() }
    }

    private var queueRefreshIdentity: SidePanelQueueRefreshIdentity {
        SidePanelQueueRefreshIdentity(
            isConnected: player.isConnected,
            currentTrackURI: player.trackURI,
            queueURIs: player.queueNextEntries.map(\.uri)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Panel", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Button("Close Inspector", systemImage: "xmark") {
                onClose()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Close inspector")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Queue

    @ViewBuilder
    private var queueList: some View {
        if !player.hasCurrentTrack && player.queueNextEntries.isEmpty {
            EmptyState(
                icon: "list.bullet.rectangle",
                title: "Nothing queued",
                message: "Play something, or use a track's context menu to add it to the queue."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if player.hasCurrentTrack {
                        Text("Now playing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        CurrentTrackRow(player: player)

                        if !player.queueNextEntries.isEmpty {
                            Text("Next up")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                        }
                    }

                    ForEach(player.queueNextEntries) { entry in
                        QueueRow(entry: entry, metadata: metadata) {
                            player.play(uri: entry.uri)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historyList: some View {
        if player.history.entries.isEmpty {
            EmptyState(
                icon: "clock.arrow.circlepath",
                title: "No listening history yet",
                message: "Tracks you play will appear here."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(player.history.entries) { entry in
                        HistoryRow(entry: entry) {
                            player.play(uri: entry.uri)
                        }
                    }
                }
                .padding(14)
            }
        }
    }
}

/// One tappable row in the queue list. Resolves its display name from the catalog
/// once per uri — queue updates carry uris only, and resolving inside body would
/// rescan loaded lists on every hover change.
private struct QueueRow: View {
    let entry: QueueEntry
    var isCurrent = false
    let metadata: CatalogMetadataRepository
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        rowBody
    }

    private var rowBody: some View {
        Button(action: action) {
            HStack(spacing: 10) {

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .opacity(isCurrent || isHovering ? 1 : 0)
            }
            .padding(6)
            .contentShape(Rectangle())
            .background(
                isHovering ? Color.primary.opacity(0.055) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .onHover { isHovering = $0 }
        // A row scrolled away under a resting cursor keeps no highlight.
        .onDisappear { isHovering = false }
        .help(isCurrent ? title : "Play \(title)")
        .accessibilityLabel("\(isCurrent ? "Now playing" : "Play") \(title), \(subtitle)")
    }

    /// Resolve at render time so a queue received before the catalog automatically gains names
    /// when Liked Songs, search, or a playlist finishes loading.
    private var title: String {
        metadata.displayInfo(for: entry.uri).title
    }

    private var subtitle: String {
        let artist = metadata.displayInfo(for: entry.uri).artist
        return title == "Unknown track" ? entry.sourceLabel : artist
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RemoteArtwork(url: entry.artworkURL, kind: .track, cornerRadius: 5, pointSize: 40)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.callout)
                        .lineLimit(1)
                    Text(entry.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(entry.playedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(6)
            .contentShape(Rectangle())
            .background(
                isHovering ? Color.primary.opacity(0.055) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // A row scrolled away under a resting cursor keeps no highlight.
        .onDisappear { isHovering = false }
        .help("Play \(entry.title)")
        .accessibilityLabel("Play \(entry.title) by \(entry.artist), played \(entry.playedAt.formatted(.relative(presentation: .named)))")
    }
}

/// The current track card at the top of the queue tab.
private struct CurrentTrackRow: View {
    let player: PlaybackStore

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(player.displayedTrackTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Text(player.displayedArtistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(6)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now playing \(player.trackTitle) by \(player.artistName)")
    }
}
