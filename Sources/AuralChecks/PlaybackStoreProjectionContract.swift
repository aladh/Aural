import Foundation

/// Line-oriented contract for `PlaybackStore+Projections.swift`.
///
/// That file owns the read-only presentation projections. An explicit `set {` / `set(`
/// accessor there would recreate partial-presentation state. `func set…` methods and
/// setters in other files are out of scope for this file-bounded guard.
enum PlaybackStoreProjectionContract {
    static func explicitSetterLines(in source: String) -> [String] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter(isExplicitSetterLine(_:))
    }

    static func isExplicitSetterLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(
            of: #"\bset\s*(\([^)]*\))?\s*\{"#,
            options: .regularExpression
        ) != nil
    }

    static func uncommentedSource(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let text = String(line)
                guard let comment = text.range(of: "//") else { return text }
                return String(text[..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }
}
