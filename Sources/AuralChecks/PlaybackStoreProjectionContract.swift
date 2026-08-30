import Foundation

/// Line-oriented contract for `PlaybackStore+Projections.swift`.
///
/// That file owns the read-only presentation projections. An explicit `set {` / `set(`
/// accessor there would recreate partial-presentation state. `func set…` methods and
/// setters in other files are out of scope for this file-bounded guard.
///
/// Matching is comment-safe: quoted strings and `//` line comments are dropped before
/// the setter pattern runs, so a documented example is not an accessor.
enum PlaybackStoreProjectionContract {
    static func explicitSetterLines(in source: String) -> [String] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter(isExplicitSetterLine(_:))
    }

    static func isExplicitSetterLine(_ line: String) -> Bool {
        let payload = lexicalPayload(in: line).trimmingCharacters(in: .whitespaces)
        return payload.range(
            of: #"\bset\s*(\([^)]*\))?\s*\{"#,
            options: .regularExpression
        ) != nil
    }

    private static func lexicalPayload(in line: String) -> String {
        var payload = ""
        payload.reserveCapacity(line.count)
        var inString = false
        for character in line {
            if character == "\"" {
                inString.toggle()
                continue
            }
            if !inString {
                payload.append(character)
            }
        }
        if let comment = payload.range(of: "//") {
            return String(payload[..<comment.lowerBound])
        }
        return payload
    }
}
