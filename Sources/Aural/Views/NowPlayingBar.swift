import SwiftUI

struct NowPlayingBar: View {
    let player: PlaybackStore
    @Binding var showsSidePanel: Bool

    var body: some View {
        HStack(spacing: 18) {
            NowPlayingTrackIdentity(player: player)
                .frame(maxWidth: .infinity, alignment: .leading)
            NowPlayingTransportControls(player: player)
                .frame(maxWidth: .infinity)
            NowPlayingTimeControls(player: player, showsSidePanel: $showsSidePanel)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: player.hasCurrentTrack ? 84 : 72)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
            NowPlayingProgress(player: player).offset(y: -8)
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
}
