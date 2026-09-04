import Foundation

/// Line-oriented contract for production `PlaybackStore.state` writers.
///
/// The snapshot may be assigned only at declaration and at the accepted reducer
/// commit in `send`. Direct member mutation belongs in `PlaybackReducer` and
/// domain helpers, not in store extensions.
enum PlaybackStoreStateWriterContract {
    static func assignmentLines(in source: String) -> [String] {
        matchingLines(in: source, pattern: #"(?<![\w.])(?:self\.)?state\s*=(?!=)"#)
            .filter { !$0.contains("let state") }
    }

    static func memberMutationLines(in source: String) -> [String] {
        matchingLines(in: source, pattern: #"(?<![\w.])(?:self\.)?state\.[A-Za-z0-9_.\[\]]+\s*=(?!=)"#)
            .filter { !$0.contains("let state") }
    }

    private static func matchingLines(in source: String, pattern: String) -> [String] {
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
