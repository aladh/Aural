import Foundation

/// Offset arithmetic for paged Spotify endpoints.
public enum Pagination {
    public static func nextOffset(offset: Int, pageEntryCount: Int, totalCount: Int?) -> Int? {
        guard pageEntryCount > 0 else { return nil }
        let fetched = offset + pageEntryCount
        if let totalCount, fetched >= totalCount { return nil }
        return fetched
    }
}

public enum SpotifyURI {
    public static func id(from uri: String) -> String? {
        let parts = uri.split(separator: ":")
        guard parts.count >= 3, parts[0] == "spotify", let last = parts.last, !last.isEmpty else {
            return nil
        }
        return String(last)
    }

    public static func id(from uri: String, kind: String) -> String? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == kind, !parts[2].isEmpty else {
            return nil
        }
        return String(parts[2])
    }
}

/// Pulls the query out of an HTTP request line without opening a socket.
///
/// The listener is registered for `http://127.0.0.1:<port>/login`. Only that origin-form
/// target is accepted, so `GET /` or a lookalike path cannot consume the one-shot callback.
public enum LoopbackRequestParser {
    public static let callbackPath = "/login"

    public static func parseRequestLine(_ request: String) -> URLComponents? {
        guard let line = firstRequestLine(request) else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET" else { return nil }
        guard parts[2].hasPrefix("HTTP/") else { return nil }
        return parseOriginFormCallbackTarget(String(parts[1]))
    }

    /// First line of an HTTP request, without CR/LF. Empty or missing lines are malformed.
    public static func firstRequestLine(_ request: String) -> String? {
        let line = request.prefix { $0 != "\n" && $0 != "\r" }
        return line.isEmpty ? nil : String(line)
    }

    /// Origin-form request-target that names exactly `/login` after percent-decoding.
    public static func parseOriginFormCallbackTarget(_ target: String) -> URLComponents? {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("://") else {
            return nil
        }
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            return nil
        }
        guard components.scheme == "http",
              components.host == "127.0.0.1",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path == callbackPath
        else {
            return nil
        }
        return components
    }
}
