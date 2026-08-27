import Foundation

/// A cookie identity used to decide Sign Out cleanup without depending on Foundation's
/// `HTTPCookie` type. Domain and path are the matching surface; values are never inspected.
public struct CookieOrigin: Equatable, Sendable {
    public var name: String
    public var domain: String
    public var path: String

    public init(name: String, domain: String, path: String) {
        self.name = name
        self.domain = domain
        self.path = path
    }
}

/// Selects Spotify authentication cookies so Sign Out can forget the grant without wiping
/// an unrelated shared cookie jar.
public enum SpotifyAuthenticationCookies {
    /// Spotify's registrable domain, including a leading-dot cookie domain and subdomains.
    public static func matchesDomain(_ domain: String) -> Bool {
        let host = normalizeDomain(domain)
        return host == "spotify.com" || host.hasSuffix(".spotify.com")
    }

    /// Cookie paths are origin-form (`/` or a subdirectory). Anything else is not ours to remove.
    public static func matchesPath(_ path: String) -> Bool {
        path.hasPrefix("/")
    }

    public static func shouldRemove(domain: String, path: String) -> Bool {
        matchesDomain(domain) && matchesPath(path)
    }

    /// Stable, idempotent selection: sorted by domain, path, then name, preserving only matches.
    public static func cookiesToRemove(_ cookies: [CookieOrigin]) -> [CookieOrigin] {
        cookies
            .filter { shouldRemove(domain: $0.domain, path: $0.path) }
            .sorted {
                ($0.domain.lowercased(), $0.path, $0.name) < ($1.domain.lowercased(), $1.path, $1.name)
            }
    }

    private static func normalizeDomain(_ domain: String) -> String {
        var host = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasPrefix(".") {
            host.removeFirst()
        }
        return host
    }
}
