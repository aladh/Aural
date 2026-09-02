import SwiftUI

struct NowPlayingBar: View {
    let player: PlaybackStore
    @Binding var showsSidePanel: Bool

    var body: some View {
        HStack(spacing: 22) {
            NowPlayingTrackIdentity(player: player)
                .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 5) {
                NowPlayingTransportControls(player: player)

                HStack(spacing: 8) {
                    Text(player.hasCurrentTrack ? formatDuration(player.position) : "—:—")
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)

                    NowPlayingProgress(player: player)

                    Text(remainingTime)
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .leading)
                }
                .font(.caption2.monospacedDigit())
            }
            .frame(maxWidth: 460)

            NowPlayingTimeControls(player: player, showsSidePanel: $showsSidePanel)
                .frame(minWidth: 210, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: player.hasCurrentTrack ? 92 : 78)
        .background {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: .top) { Divider() }
        }
        .animation(.snappy(duration: 0.2), value: player.hasCurrentTrack)
        .task(id: player.showsPauseControl) {
            guard player.showsPauseControl else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                player.refreshPosition()
            }
        }
    }

    private var remainingTime: String {
        guard player.hasCurrentTrack, player.duration > 0 else { return "—:—" }
        return "−\(formatDuration(max(0, player.duration - player.position)))"
    }
}
