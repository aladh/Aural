import SwiftUI

struct AccountCommands: Commands {
    let player: PlaybackStore

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Sign Out") {
                Task { await player.logout() }
            }
            .disabled(!player.isConnected)

            Divider()
        }
    }
}

struct PlaybackCommands: Commands {
    let player: PlaybackStore

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play/Pause") {
                player.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!player.canTogglePlayback)

            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!player.canSkipTrack)

            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!player.canSkipTrack)

            Divider()

            Button("Toggle Shuffle") {
                player.toggleShuffle()
            }
            .disabled(!player.canStartPlayback)

            Button("Cycle Repeat Mode") {
                player.cycleRepeat()
            }
            .disabled(!player.canStartPlayback)
        }
    }
}
