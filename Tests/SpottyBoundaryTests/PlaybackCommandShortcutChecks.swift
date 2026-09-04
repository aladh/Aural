import Foundation
import Testing

@Suite("Playback command shortcut checks")
@MainActor
struct PlaybackCommandShortcutChecks {
    @Test("track shortcuts preserve standard text-field line navigation")
    func trackShortcutsPreserveTextFieldNavigation() throws {
        let source = try playbackCommandsSource()

        #expect(!source.contains(".keyboardShortcut(.leftArrow, modifiers: .command)"))
        #expect(!source.contains(".keyboardShortcut(.rightArrow, modifiers: .command)"))
        #expect(source.contains(".keyboardShortcut(.leftArrow, modifiers: [.command, .shift])"))
        #expect(source.contains(".keyboardShortcut(.rightArrow, modifiers: [.command, .shift])"))
    }
}

private func playbackCommandsSource() throws -> String {
    let checksDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repositoryRoot = checksDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let url = repositoryRoot.appending(path: "Sources/Spotty/PlaybackCommands.swift")
    return try String(contentsOf: url, encoding: .utf8)
}
