import Foundation

/// Line-oriented contract for `CatalogPlaybackAccess.swift` and the RootView accessor.
///
/// Constructing the access value must not snapshot playback facts. Action closures
/// rebuilt on every body pass are out of contract; methods on a store-identity
/// value are the accepted shape.
enum CatalogPlaybackAccessSourceContract {
    static let playbackFactTokens = [
        "isConnected",
        "accountEpoch",
        "canStartPlayback",
        "hasCurrentTrack",
        "trackURI",
        "statusText",
        "pendingCommands",
        "transientCommandError",
        "activeRemoteDevice",
    ]

    static func initializerBody(in source: String) -> String {
        guard let start = source.range(of: "init(player: PlaybackStore)") else { return "" }
        let fromInit = source[start.lowerBound...]
        guard let open = fromInit.range(of: "{") else { return "" }
        let rest = fromInit[open.upperBound...]
        if let end = rest.range(of: "\n    }") {
            return String(rest[..<end.lowerBound])
        }
        return String(rest)
    }

    static func factTokensRead(in text: String) -> [String] {
        playbackFactTokens.filter { text.contains($0) }
    }

    static func storedActionClosureLines(in source: String) -> [String] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.hasPrefix("//") else { return false }
                if line.hasPrefix("func ") || line.hasPrefix("static func ") { return false }
                return line.contains("-> Void")
                    || line.contains(": @MainActor (")
                    || line.contains(": @MainActor(")
            }
    }

    static func equatesByPlayerIdentity(_ source: String) -> Bool {
        source.contains("nonisolated static func ==")
            && (
                source.contains("lhs.player === rhs.player")
                    || source.contains("rhs.player === lhs.player")
                    || source.contains("lhs.playerIdentity == rhs.playerIdentity")
                    || source.contains("rhs.playerIdentity == lhs.playerIdentity")
            )
    }

    static func catalogPlaybackAccessorBody(in rootViewSource: String) -> String {
        guard let start = rootViewSource.range(of: "private var catalogPlayback: CatalogPlaybackAccess")
        else { return "" }
        let fromAccessor = rootViewSource[start.lowerBound...]
        guard let open = fromAccessor.range(of: "{") else { return "" }
        let rest = fromAccessor[open.upperBound...]
        if let end = rest.range(of: "\n    }") {
            return String(rest[..<end.lowerBound])
        }
        return String(rest)
    }
}
