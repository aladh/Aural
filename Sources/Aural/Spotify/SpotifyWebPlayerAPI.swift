import Foundation

nonisolated enum SpotifyWebPlayerAPIError: Error, LocalizedError {
    case malformedResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            "Spotify returned an unreadable queue"
        case let .requestFailed(status, detail):
            detail.isEmpty
                ? "Spotify rejected the queue request (HTTP \(status))"
                : "Spotify rejected the queue request (HTTP \(status)): \(detail)"
        }
    }

    var statusCode: Int? {
        guard case let .requestFailed(status, _) = self else { return nil }
        return status
    }
}

/// The documented Web API queue endpoint. Aural prefers this because it returns the exact
/// cross-device queue with display metadata in one response. Some first-party grants are
/// rate-limited at the Web API boundary, so callers retain the Connect-cluster fallback.
nonisolated struct SpotifyWebPlayerAPI: Sendable {
    typealias Transport = SpotifyCredentials.Transport

    static let queueURL = URL(string: "https://api.spotify.com/v1/me/player/queue")!

    private let accessToken: @Sendable () async throws -> String
    private let transport: Transport

    init(
        accessToken: @escaping @Sendable () async throws -> String = {
            try await KeymasterSession.shared.accessToken()
        },
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.accessToken = accessToken
        self.transport = transport
    }

    func queue() async throws -> [CatalogTrack] {
        var request = URLRequest(url: Self.queueURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await request.setValue("Bearer \(accessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyWebPlayerAPIError.malformedResponse
        }
        guard http.statusCode == 200 else {
            throw SpotifyWebPlayerAPIError.requestFailed(
                http.statusCode,
                String(decoding: data.prefix(300), as: UTF8.self)
            )
        }
        return try Self.decodeQueue(data)
    }

    static func decodeQueue(_ data: Data) throws -> [CatalogTrack] {
        let response: QueueResponse
        do {
            response = try JSONDecoder().decode(QueueResponse.self, from: data)
        } catch {
            throw SpotifyWebPlayerAPIError.malformedResponse
        }
        return response.queue.map(\.catalogTrack)
    }
}

private nonisolated struct QueueResponse: Decodable, Sendable {
    let queue: [Item]

    struct Item: Decodable, Sendable {
        struct Artist: Decodable, Sendable { let name: String }
        struct Image: Decodable, Sendable {
            let url: URL
            let width: Int?
            let height: Int?
        }
        struct Album: Decodable, Sendable {
            let name: String?
            let images: [Image]?
        }
        struct Show: Decodable, Sendable {
            let name: String?
            let publisher: String?
            let images: [Image]?
        }

        let id: String?
        let uri: String
        let name: String
        let durationMS: Int?
        let artists: [Artist]?
        let album: Album?
        let show: Show?

        enum CodingKeys: String, CodingKey {
            case id, uri, name, artists, album, show
            case durationMS = "duration_ms"
        }

        var catalogTrack: CatalogTrack {
            let creator = artists?.map(\.name).joined(separator: ", ")
            let creditedArtist = creator.flatMap { $0.isEmpty ? nil : $0 }
            let images = album?.images ?? show?.images ?? []
            let artworkURL = images.max {
                ($0.width ?? $0.height ?? 0) < ($1.width ?? $1.height ?? 0)
            }?.url
            return CatalogTrack(
                id: id ?? uri,
                uri: uri,
                title: name,
                artist: creditedArtist ?? show?.publisher ?? show?.name ?? "Spotify",
                album: album?.name ?? show?.name ?? "",
                duration: TimeInterval(durationMS ?? 0) / 1_000,
                artworkURL: artworkURL,
                addedAt: nil
            )
        }
    }
}
