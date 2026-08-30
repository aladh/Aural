import Foundation

/// Line-oriented contract for production playback timestamp ownership.
///
/// Store intake, timing anchors, engine fan-out receipt, and played-history
/// stamps must use the injected `PlaybackClock`. `Date()` remains allowed in
/// domain value conveniences that cannot reach production orchestration.
enum PlaybackStoreClockStampingContract {
    static let storeFiles = [
        "PlaybackStore.swift",
        "PlaybackStore+Commands.swift",
        "PlaybackStore+EngineEvents.swift",
        "PlaybackStore+History.swift",
        "PlaybackStore+Projections.swift",
        "PlaybackStore+Queue.swift",
        "PlaybackStore+Session.swift",
        "PlaybackStore+Transport.swift",
    ]

    static func dateCallLines(in source: String) -> [String] {
        matchingLines(in: source, pattern: #"\bDate\s*\(\s*\)"#)
    }

    static func matchingLines(in source: String, pattern: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { return nil }
            let range = NSRange(location: 0, length: (trimmed as NSString).length)
            guard regex.firstMatch(in: trimmed, range: range) != nil else { return nil }
            return trimmed
        }
    }
}
