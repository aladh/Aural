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
public enum LoopbackRequestParser {
    public static func parseRequestLine(_ request: String) -> URLComponents? {
        guard let line = request.split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return URLComponents(string: "http://127.0.0.1\(parts[1])")
    }
}
