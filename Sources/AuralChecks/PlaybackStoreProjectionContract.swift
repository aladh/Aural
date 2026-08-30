import Foundation

/// Line-oriented contract for `PlaybackStore+Projections.swift`.
///
/// That file owns the read-only presentation projections. An explicit `set {` / `set(`
/// accessor there would recreate partial-presentation state. `func set…` methods and
/// setters in other files are out of scope for this file-bounded guard.
///
/// Comment and string handling uses `uncommentedSource` on the whole buffer. Nested
/// `/* */` state carries across lines because block-comment newlines are kept. Setter
/// detection then drops remaining quoted string contents so a documented example is
/// not an accessor.
enum PlaybackStoreProjectionContract {
    static func explicitSetterLines(in source: String) -> [String] {
        let originalLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let uncommentedLines = uncommentedSource(source).split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        return zip(originalLines, uncommentedLines).compactMap { original, uncommented in
            isExplicitSetterPayload(uncommented) ? original : nil
        }
    }

    static func isExplicitSetterLine(_ line: String) -> Bool {
        isExplicitSetterPayload(uncommentedSource(line))
    }

    private static func isExplicitSetterPayload(_ uncommentedLine: String) -> Bool {
        let payload = uncommentedLine
            .replacingOccurrences(of: #"\"([^"\\]|\\.)*\""#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return payload.range(
            of: #"\bset\s*(\([^)]*\))?\s*\{"#,
            options: .regularExpression
        ) != nil
    }

    static func uncommentedSource(_ source: String) -> String {
        var result = ""
        var index = source.startIndex
        var blockDepth = 0
        var inLineComment = false
        var inString = false
        var escaped = false
        while index < source.endIndex {
            let next = source.index(after: index)
            let startsPair = next < source.endIndex
            let pair = startsPair ? String(source[index...next]) : ""
            let character = source[index]

            if inLineComment {
                if character == "\n" {
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
                    if character == "\n" {
                        result.append("\n")
                    }
                    index = next
                }
                continue
            }

            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = next
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

            if character == "\"" {
                inString = true
            }
            result.append(character)
            index = next
        }
        return result
    }

    static func containsUncommented(_ source: String, _ token: String) -> Bool {
        uncommentedSource(source).contains(token)
    }
}
