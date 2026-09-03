import AppKit
import SwiftUI

struct NowPlayingTrackIdentity: View {
    let player: PlaybackStore

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if player.hasCurrentTrack {
                    RemoteArtwork(url: player.displayedArtworkURL, kind: .track, cornerRadius: 3, pointSize: 44)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary)
                        Image(systemName: "music.note")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(AuralPalette.playerSecondary)
                    }
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(AuralPalette.playerDivider) }
                    .accessibilityHidden(true)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.displayedTrackTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AuralPalette.playerPrimary)
                    .lineLimit(1)
                Text(player.displayedArtistName)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(AuralPalette.playerSecondary)
                    .lineLimit(1)
            }
            .contentTransition(.opacity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            player.hasCurrentTrack
                ? "Now playing \(player.displayedTrackTitle) by \(player.displayedArtistName)"
                : "No track playing"
        )
    }
}

struct NowPlayingProgress: View {
    let player: PlaybackStore
    @State private var isHovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.showsPauseControl)) { timeline in
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.20)).frame(height: height)
                    if player.hasCurrentTrack {
                        Capsule().fill(isHovering ? AuralPalette.mediaGreen : AuralPalette.playerPrimary)
                            .frame(width: proxy.size.width * fraction(at: timeline.date), height: height)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { point in
                    guard player.canStartPlayback, player.hasCurrentTrack, player.duration > 0 else { return }
                    player.seek(to: point.x / max(proxy.size.width, 1))
                }
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement()
        .accessibilityHidden(!player.hasCurrentTrack)
        .accessibilityLabel("Playback position")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction(adjust)
        .frame(height: 16)
        .animation(.snappy(duration: 0.2), value: isHovering)
    }

    private var height: CGFloat { isHovering && player.hasCurrentTrack ? 4 : 3 }
    private func fraction(at date: Date) -> Double {
        guard player.hasCurrentTrack, player.duration > 0 else { return 0 }
        return min(max(player.displayedPosition(at: date) / player.duration, 0), 1)
    }
    private var accessibilityValue: String {
        guard player.hasCurrentTrack else { return "No current track" }
        return "\(formatDuration(player.position)) of \(formatDuration(player.duration))"
    }
    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard player.canStartPlayback, player.duration > 0 else { return }
        let step = 10 / player.duration
        switch direction {
        case .increment: player.seek(to: fraction(at: Date()) + step)
        case .decrement: player.seek(to: fraction(at: Date()) - step)
        @unknown default: break
        }
    }
}

struct NowPlayingTransportControls: View {
    let player: PlaybackStore

    var body: some View {
        HStack(spacing: 16) {
            optionButton(
                symbol: "shuffle",
                active: player.isShuffleEnabled,
                label: player.isShuffleEnabled ? "Shuffle on, fewer repeats" : "Shuffle off",
                help: player.isShuffleEnabled ? "Fewer repeats shuffle is on" : "Turn on fewer repeats shuffle",
                action: player.toggleShuffle
            )
            TransportIconButton(
                symbol: "backward.end.fill", label: "Previous", disabled: !player.canSkipTrack, action: player.previous)
            Button(action: player.togglePlayback) {
                ZStack {
                    Circle().fill(player.canTogglePlayback ? AuralPalette.playerPrimary : Color.white.opacity(0.20))
                    Image(systemName: player.showsPauseControl ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(
                            player.canTogglePlayback
                                ? Color.black
                                : Color(nsColor: .tertiaryLabelColor)
                        )
                        .offset(x: player.showsPauseControl ? 0 : 1)
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!player.canTogglePlayback)
            .help(player.hasCurrentTrack ? (player.showsPauseControl ? "Pause" : "Play") : "Choose music to begin")
            .accessibilityLabel(player.showsPauseControl ? "Pause" : "Play")
            TransportIconButton(
                symbol: "forward.end.fill", label: "Next", disabled: !player.canSkipTrack, action: player.next)
            optionButton(
                symbol: player.repeatMode.symbolName,
                active: player.repeatMode != .off,
                label: player.repeatMode.accessibilityLabel,
                help: player.repeatMode.accessibilityLabel,
                action: player.cycleRepeat
            )
        }
    }

    private func optionButton(
        symbol: String,
        active: Bool,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    active ? AuralPalette.mediaGreen : AuralPalette.playerSecondary
                )
                .frame(width: 26, height: 26)
                .overlay(alignment: .bottom) {
                    if active {
                        Circle().fill(AuralPalette.mediaGreen).frame(width: 3, height: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!player.canStartPlayback)
        .help(help)
        .accessibilityLabel(label)
    }
}

struct NowPlayingTimeControls: View {
    let player: PlaybackStore
    @Binding var showsSidePanel: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showsSidePanel.toggle() }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        showsSidePanel ? AuralPalette.playerPrimary : AuralPalette.playerSecondary
                    )
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsSidePanel ? "Hide queue and history" : "Show queue and history")
            .accessibilityLabel(showsSidePanel ? "Hide queue and history panel" : "Show queue and history panel")
            devicesMenu
        }
        .font(.caption2.monospacedDigit())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback devices and queue controls")
    }

    private var devicesMenu: some View {
        Menu {
            Section("Spotify Connect") {
                ForEach(player.connectDevices) { device in
                    Button {
                        player.transferPlayback(to: device)
                    } label: {
                        Label(deviceName(device), systemImage: device.symbolName)
                    }
                    .disabled(device.isActive || device.id == player.activeRemoteDevice?.id)
                }
                if player.connectDevices.isEmpty { Text("No devices found") }
            }
        } label: {
            Image(systemName: "display.2")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AuralPalette.playerSecondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(player.connectDevices.isEmpty && !player.isConnected)
        .help("Choose playback device")
        .accessibilityLabel("Playback devices")
    }

    private func deviceName(_ device: ConnectDevice) -> String {
        if device.id == player.localDeviceID { return "\(device.name) (This Mac)" }
        if device.id == player.activeRemoteDevice?.id {
            return "\(device.name) (\(player.isPlaying ? "Playing" : "Paused"))"
        }
        return device.displayName(localDeviceID: player.localDeviceID)
    }
}

private struct TransportIconButton: View {
    let symbol: String
    let label: String
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AuralPalette.playerSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
