import Foundation

/// Stable HTTP status text for Spotify API errors that can reach UI or public logs.
enum SpotifyHTTPFailure {
    static func description(status: Int) -> String {
        "HTTP \(status)"
    }
}
