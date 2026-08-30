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

    static func initializerBody(in source: String) -> String {
        braceBody(after: "init(player: PlaybackStore)", in: source)
    }

    static func catalogPlaybackAccessorBody(in rootViewSource: String) -> String {
        braceBody(after: "private var catalogPlayback: CatalogPlaybackAccess", in: rootViewSource)
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
            let isTypedClosureProperty = (line.hasPrefix("let ") || line.hasPrefix("var "))
                && (
                    line.contains("-> Void")
                        || line.contains(": @MainActor (")
                        || line.contains(": @MainActor(")
                )
            let isInferredClosureProperty = (line.hasPrefix("let ") || line.hasPrefix("var "))
                && line.contains("= {")
            return isTypedClosureProperty || isInferredClosureProperty
        }
    }

    static func equatesByPlayerIdentity(_ source: String) -> Bool {
        source.contains("nonisolated static func ==")
            && source.contains("lhs.playerIdentity == rhs.playerIdentity")
    }

    private static func braceBody(after marker: String, in source: String) -> String {
        guard let start = source.range(of: marker) else { return "" }
        let fromMarker = source[start.lowerBound...]
        guard let open = fromMarker.range(of: "{") else { return "" }
        let rest = fromMarker[open.upperBound...]
        if let end = rest.range(of: "\n    }") {
            return String(rest[..<end.lowerBound])
        }
        return String(rest)
    }
}
