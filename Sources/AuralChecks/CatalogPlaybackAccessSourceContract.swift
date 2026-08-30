import Foundation

/// Line-oriented contract for `CatalogPlaybackAccess` construction and RootView wiring.
///
/// The initializer may only store the player (and its identity for `Equatable`). Any
/// copied playback fact or per-body action closure is out of contract.
enum CatalogPlaybackAccessSourceContract {
    static let allowedInitializerLines = [
        "self.player = player",
        "self.playerIdentity = ObjectIdentifier(player)",
    ]

    static let allowedRootAccessorLines = [
        "CatalogPlaybackAccess(player: player)",
    ]

    static let allowedEqualityLines = [
        "lhs.playerIdentity == rhs.playerIdentity",
    ]

    static func initializerBody(in source: String) -> String {
        braceBody(after: "init(player: PlaybackStore)", in: source)
    }

    static func catalogPlaybackAccessorBody(in rootViewSource: String) -> String {
        braceBody(after: "private var catalogPlayback: CatalogPlaybackAccess", in: rootViewSource)
    }

    static func equalityBody(in source: String) -> String {
        braceBody(after: "nonisolated static func ==", in: source)
    }

    static func significantLines(in text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
    }

    static func storedActionClosureLines(in source: String) -> [String] {
        significantLines(in: source).filter { line in
            if line.contains("func ") { return false }
            guard isStoredPropertyDeclaration(line) else { return false }
            return line.contains("-> Void")
                || line.contains(": @MainActor (")
                || line.contains(": @MainActor(")
                || line.contains("= {")
        }
    }

    static func equatesByPlayerIdentity(_ source: String) -> Bool {
        source.contains("nonisolated static func ==")
            && significantLines(in: equalityBody(in: source)) == allowedEqualityLines
    }

    private static func isStoredPropertyDeclaration(_ line: String) -> Bool {
        line.hasPrefix("let ")
            || line.hasPrefix("var ")
            || line.contains(" let ")
            || line.contains(" var ")
    }

    private static func braceBody(after marker: String, in source: String) -> String {
        guard let start = source.range(of: marker) else { return "" }
        let fromMarker = source[start.lowerBound...]
        guard let open = fromMarker.range(of: "{") else { return "" }
        var collected: [String] = []
        for line in String(fromMarker[open.upperBound...]).split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            if line.trimmingCharacters(in: .whitespaces) == "}" { break }
            collected.append(String(line))
        }
        return collected.joined(separator: "\n")
    }
}
