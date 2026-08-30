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
        var result = ""
        var index = source.startIndex
        var blockDepth = 0
        var inLineComment = false
        while index < source.endIndex {
            let next = source.index(after: index)
            let startsPair = next < source.endIndex
            let pair = startsPair ? String(source[index...next]) : ""

            if inLineComment {
                if source[index] == "\n" {
                    inLineComment = false
                    result.append("\n")
                }
                index = next
                continue
            }

            if blockDepth > 0 {
                if pair == "/*" {
                    blockDepth += 1
                    index = source.index(after: next)
                } else if pair == "*/" {
                    blockDepth -= 1
                    index = source.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if pair == "/*" {
                blockDepth = 1
                index = source.index(after: next)
                continue
            }
            if pair == "//" {
                inLineComment = true
                index = source.index(after: next)
                continue
            }

            result.append(source[index])
            index = next
        }
        return result
    }

    static func containsUncommented(_ source: String, _ token: String) -> Bool {
        uncommentedSource(source).contains(token)
    }
}
