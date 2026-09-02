//
//  SidePanelView.swift
//  Aural
//
//  The right-hand playback panel: the play queue and the recently played list.
//

import AuralDomain
import SwiftUI

/// Restarts queue hydration when launch-time Connect ordering arrives after the account becomes
/// ready. Queue snapshots produced by that hydration deliberately do not change this identity,
/// avoiding a redundant second refresh while ordering and metadata converge.
struct SidePanelQueueRefreshIdentity: Equatable {
    let isConnected: Bool
    let currentTrackURI: String
    let connectOrderingVersion: UInt64
}

struct SidePanelView: View {
    let metadata: CatalogMetadataRepository
    let player: PlaybackStore
    let onClose: () -> Void

    @State private var tab: Tab = .queue
    @State private var upcomingSelection: Set<QueueEntry.ID> = []

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
        .background(.bar)
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
            connectOrderingVersion: player.queueInspectorOrderingVersion
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
            .controlSize(.small)
            .font(.caption)
            .frame(width: 136)

            Spacer(minLength: 0)

            Button("Close Inspector", systemImage: "xmark") {
                onClose()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Close inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
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
            List(selection: $upcomingSelection) {
                if player.hasCurrentTrack {
                    Section {
                        CurrentTrackRow(player: player)
                    } header: {
                        railSectionHeader("Now playing")
                    }
                }

                if !player.queueNextEntries.isEmpty {
                    Section {
                        ForEach(player.queueNextEntries) { entry in
                            QueueUpcomingRow(entry: entry, metadata: metadata)
                                .tag(entry.id)
                        }
                    } header: {
                        railSectionHeader("Next up")
                    }
                }
            }
            .listStyle(.plain)
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .environment(\.defaultMinListRowHeight, 46)
            .contextMenu(forSelectionType: QueueEntry.ID.self) { selectedIDs in
                let selected = QueueMutationSelection.orderedUpcoming(
                    selectedIDs: selectedIDs,
                    in: player.queueNextEntries
                )
                if selected.count == 1, let entry = selected.first {
                    Button("Play", systemImage: "play.fill") {
                        player.play(uri: entry.uri)
                    }
                    .disabled(!player.canStartPlayback)
                }
                if !selected.isEmpty {
                    Button("Remove from Queue", role: .destructive) {
                        player.removeUpcomingQueueOccurrences(selectedIDs: selectedIDs)
                    }
                    .disabled(!player.canRemoveUpcomingQueue(selectedIDs: selectedIDs))
                }
            } primaryAction: { selectedIDs in
                let selected = QueueMutationSelection.orderedUpcoming(
                    selectedIDs: selectedIDs,
                    in: player.queueNextEntries
                )
                guard selected.count == 1, let entry = selected.first else { return }
                guard player.canStartPlayback else { return }
                player.play(uri: entry.uri)
            }
            .onDeleteCommand {
                let selectedCount = QueueMutationSelection.orderedUpcoming(
                    selectedIDs: upcomingSelection,
                    in: player.queueNextEntries
                ).count
                guard
                    QueueMutationSelection.keyboardCommand(
                        deleteOrBackspace: true,
                        selectedUpcomingCount: selectedCount,
                        isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: upcomingSelection)
                    ) == .removeUpcomingOccurrences
                else {
                    return
                }
                player.removeUpcomingQueueOccurrences(selectedIDs: upcomingSelection)
            }
            .onChange(of: player.queueNextEntries.map(\.id), initial: true) { _, ids in
                upcomingSelection.formIntersection(Set(ids))
            }
            .accessibilityLabel("Queue")
        }
    }

    private func railSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
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
                .padding(12)
            }
        }
    }
}

/// One selectable upcoming queue row. Playback is Return/double-click via the list
/// primary action, not a single click, so selection and removal stay distinct.
private struct QueueUpcomingRow: View {
    let entry: QueueEntry
    let metadata: CatalogMetadataRepository

    var body: some View {
        let displayInfo = metadata.displayInfo(for: entry.uri)
        let subtitle = displayInfo.title == "Unknown track" ? entry.sourceLabel : displayInfo.artist
        let track = metadata.knownTrack(for: entry.uri)
        let durationText = track.flatMap { $0.duration > 0 ? formatDuration($0.duration) : nil }

        HStack(spacing: 10) {
            RemoteArtwork(url: track?.artworkURL, kind: .track, cornerRadius: 5, pointSize: 34)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayInfo.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let durationText {
                Text(durationText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(
            [displayInfo.title, subtitle, durationText].compactMap { $0 }.joined(separator: ", ")
        )
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
            .padding(4)
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
        .accessibilityLabel(
            "Play \(entry.title) by \(entry.artist), played \(entry.playedAt.formatted(.relative(presentation: .named)))"
        )
    }
}

/// The current track card at the top of the queue tab.
private struct CurrentTrackRow: View {
    let player: PlaybackStore

    var body: some View {
        HStack(spacing: 10) {
            RemoteArtwork(url: player.displayedArtworkURL, kind: .track, cornerRadius: 5, pointSize: 34)
                .frame(width: 34, height: 34)

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

            VStack(alignment: .trailing, spacing: 3) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                if player.duration > 0 {
                    Text(formatDuration(player.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(currentTrackAccessibilityLabel)
    }

    private var currentTrackAccessibilityLabel: String {
        let identity = "Now playing \(player.displayedTrackTitle) by \(player.displayedArtistName)"
        guard player.duration > 0 else { return identity }
        return "\(identity), \(formatDuration(player.duration))"
    }
}
