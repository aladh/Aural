import SwiftUI

struct NowPlayingBar: View {
    let player: PlaybackStore
    @Binding var showsSidePanel: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                NowPlayingTrackIdentity(player: player)
                    .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 5) {
                    NowPlayingTransportControls(player: player)

                    HStack(spacing: 8) {
                        Text(player.hasCurrentTrack ? formatDuration(player.position) : "—:—")
                            .foregroundStyle(AuralPalette.playerSecondary)
                            .frame(width: 34, alignment: .trailing)

                        NowPlayingProgress(player: player)

                        Text(remainingTime)
                            .foregroundStyle(AuralPalette.playerSecondary)
                            .frame(width: 34, alignment: .leading)
                    }
                    .font(.system(size: 9, weight: .regular, design: .rounded).monospacedDigit())
                }
                .frame(minWidth: 500, maxWidth: 520)

                NowPlayingTimeControls(player: player, showsSidePanel: $showsSidePanel)
                    .frame(minWidth: 190, maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: player.hasCurrentTrack ? 64 : 60)
            .background {
                Rectangle()
                    .fill(AuralPalette.playerShelf)
                    .overlay(alignment: .top) {
                        Rectangle().fill(AuralPalette.playerDivider).frame(height: 1)
                    }
            }

            if let banner = player.remotePlaybackBanner {
                RemotePlaybackBanner(device: banner.device, isPlaying: banner.isPlaying)
            }
        }
        .animation(.snappy(duration: 0.2), value: player.hasCurrentTrack)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.2),
            value: player.remotePlaybackBanner?.device.id
        )
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

private struct RemotePlaybackBanner: View {
    let device: ConnectDevice
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 5) {
            Spacer(minLength: 0)
            Image(systemName: "airplayaudio")
                .font(.system(size: 10, weight: .bold))
            Text("\(isPlaying ? "Playing" : "Paused") on \(device.name)")
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(AuralPalette.remotePlaybackForeground)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .background(AuralPalette.mediaGreen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isPlaying ? "Playing" : "Paused") on \(device.name)")
    }
}
