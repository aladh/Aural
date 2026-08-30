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

    static func dateCallLines(in source: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\bDate\s*\(\s*\)"#)
        return source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            let code = codeWithoutCommentsAndStrings(trimmed)
            guard !code.isEmpty else { return nil }
            let range = NSRange(location: 0, length: (code as NSString).length)
            guard regex.firstMatch(in: code, range: range) != nil else { return nil }
            return trimmed
        }
    }

    /// Drops comments and string literals so a `Date()` hygiene scan does not
    /// treat documentation or messages as executable stamps.
    private static func codeWithoutCommentsAndStrings(_ source: String) -> String {
        var result = ""
        var index = source.startIndex
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if inLineComment {
                index = next
                continue
            }
            if inBlockComment {
                if character == "*", next < source.endIndex, source[next] == "/" {
                    inBlockComment = false
                    index = source.index(after: next)
                    continue
                }
                index = next
                continue
            }
            if inString {
                if character == "\\", next < source.endIndex {
                    index = source.index(after: next)
                    continue
                }
                if character == "\"" {
                    inString = false
                }
                index = next
                continue
            }
            if character == "/", next < source.endIndex {
                switch source[next] {
                case "/":
                    inLineComment = true
                    index = source.index(after: next)
                    continue
                case "*":
                    inBlockComment = true
                    index = source.index(after: next)
                    continue
                default:
                    break
                }
            }
            if character == "\"" {
                inString = true
                index = next
                continue
            }
            result.append(character)
            index = next
        }
        return result
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
