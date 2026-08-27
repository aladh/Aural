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
        guard trimmed.hasPrefix("set") else { return false }
        let afterSet = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return afterSet.hasPrefix("{") || afterSet.hasPrefix("(")
    }
}
