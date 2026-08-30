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

    static func displayedTrackTitlePrefersCatalog(in source: String) -> Bool {
        containsTrimmedLine(
            source,
            "var displayedTrackTitle: String { catalogCurrentTrack?.title ?? trackTitle }"
        )
    }

    static func displayedArtistNamePrefersCatalog(in source: String) -> Bool {
        containsTrimmedLine(
            source,
            "var displayedArtistName: String { catalogCurrentTrack?.artist ?? artistName }"
        )
    }

    private static func containsTrimmedLine(_ source: String, _ expected: String) -> Bool {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == expected }
    }
}

/// Source contract for the queue now-playing row: VoiceOver must use the same catalog-enriched
/// title and artist projections as the visible text.
enum CurrentTrackRowAccessibilityContract {
    static func typeBody(named typeName: String, in source: String) -> String? {
        guard let header = source.range(of: "struct \(typeName)") else { return nil }
        guard let openBrace = source[header.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[openBrace...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    static func accessibilityLabelUsesDisplayedProjections(in row: String) -> Bool {
        containsQuotedAccessibilityLabel(
            row,
            "Now playing \\(player.displayedTrackTitle) by \\(player.displayedArtistName)"
        )
    }

    static func combinesChildren(in row: String) -> Bool {
        collapsed(row).contains(".accessibilityElement(children: .combine)")
    }

    static func usesRawEngineFallbacks(in row: String) -> Bool {
        collapsed(row).contains("player.trackTitle") || collapsed(row).contains("player.artistName")
    }

    static func currentTrackRowIsIdleGated(in source: String) -> Bool {
        collapsed(source).contains(
            "if player.hasCurrentTrack { Section(\"Now playing\") { CurrentTrackRow(player: player) }"
        )
    }

    static func containsQuotedAccessibilityLabel(_ source: String, _ quoted: String) -> Bool {
        normalizeFormattingOutsideStrings(source).contains(
            normalizeFormattingOutsideStrings(".accessibilityLabel(\"\(quoted)\")")
        )
    }

    static func collapsed(_ source: String) -> String {
        source.split { $0.isWhitespace }.joined(separator: " ")
    }

    /// Removes Swift formatting whitespace outside quoted literals so wrapped
    /// `.accessibilityLabel(` calls match, while spaces inside the spoken string stay significant.
    static func normalizeFormattingOutsideStrings(_ source: String) -> String {
        var result = ""
        var inString = false
        var escaped = false
        for character in source {
            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character.isWhitespace {
                continue
            }

            if character == "\"" {
                inString = true
            }
            result.append(character)
        }
        return result
    }
}
