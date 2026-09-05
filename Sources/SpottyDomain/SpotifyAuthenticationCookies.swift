import Foundation

/// Selects Spotify authentication cookies so Sign Out can forget the grant without wiping
/// an unrelated shared cookie jar. Values are never inspected.
public enum SpotifyAuthenticationCookies {
    public static func shouldRemove(domain: String, path: String) -> Bool {
        matchesDomain(domain) && matchesPath(path)
    }

    /// Spotify's registrable domain, including a leading-dot cookie domain and subdomains.
    private static func matchesDomain(_ domain: String) -> Bool {
        let host = normalizeDomain(domain)
        return host == "spotify.com" || host.hasSuffix(".spotify.com")
    }

    /// Cookie paths are origin-form (`/` or a subdirectory). Anything else is not ours to remove.
    private static func matchesPath(_ path: String) -> Bool {
        path.hasPrefix("/")
    }

    private static func normalizeDomain(_ domain: String) -> String {
        var host = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasPrefix(".") {
            host.removeFirst()
        }
        return host
    }
}
