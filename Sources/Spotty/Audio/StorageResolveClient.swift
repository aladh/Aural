//
//  StorageResolveClient.swift
//  Spotty
//
//  Asks spclient which CDN serves one audio file, and picks a URL that will still be valid when
//  the fetch actually runs. Decoding and expiry policy are pure and live in SpottyDomain
//  (`StorageResolveResponse`, `CDNURLExpiry`); this file is only the signed request around them.
//
//  Signed with the same keymaster bearer plus client token every other spclient call in this app
//  carries (`SpotifyCredentials.sign`). Whether this particular endpoint accepts that pair is one
//  of the live-only questions #208 records — extended-metadata does, which is the evidence there
//  is. The CDN fetch that follows is deliberately unsigned: those URLs are pre-signed.
//

import SpottyDomain
import Foundation

enum StorageResolveError: Error, Sendable, Equatable {
    /// The response decoded but named `STORAGE` or `RESTRICTED` rather than `CDN`. Stage 1 only
    /// plays CDN-served files; a restricted file is unplayable in this market.
    case notServedFromCDN
    /// Every returned URL is unparseable or already inside the expiry margin.
    case noUsableURL
    case httpStatus(Int)
}

/// Resolves one file id to a currently-usable CDN URL.
nonisolated struct StorageResolveClient: Sendable {
    static let baseURL = URL(string: "https://spclient.wg.spotify.com/")!

    private let credentials: SpotifyCredentials
    private let now: @Sendable () -> Date

    init(
        accessToken: @escaping @Sendable () async throws -> String = {
            try await KeymasterSession.shared.accessToken()
        },
        clientToken: @escaping @Sendable () async throws -> String = {
            try await ClientTokenProvider.shared.token()
        },
        transport: @escaping SpotifyCredentials.Transport = { try await URLSession.shared.data(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        credentials = SpotifyCredentials(
            accessToken: accessToken,
            clientToken: clientToken,
            invalidateAccessToken: SpotifyCredentials.invalidateSharedAccess,
            invalidateClientToken: SpotifyCredentials.invalidateShared,
            transport: transport,
            retryTiming: .production
        )
        self.now = now
    }

    /// The first CDN URL for `fileID` that is not already expiring, in the order Spotify
    /// returned them.
    ///
    /// `fileID` is the 20 raw bytes of the content file id; the endpoint takes them lowercase
    /// hex. `interactive` is the intent librespot uses for user-initiated playback (as opposed
    /// to `interactive_prefetch`), and it is what decides the URL's lifetime.
    func resolve(fileID: [UInt8]) async throws -> URL {
        let hex = fileID.map { String(format: "%02x", $0) }.joined()
        let url = Self.baseURL.appending(path: "storage-resolve/files/audio/interactive/\(hex)")

        // Signed inside the retry closure, not once outside it: a 401 replay has to carry the
        // credentials the refusal caused to be refreshed, not the pair that was already refused.
        let sent = try await credentials.retryingRefusedToken(replay: .safe) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            try await credentials.sign(&request)
            let (body, response) = try await credentials.transport(request)
            guard let http = response as? HTTPURLResponse else {
                throw StorageResolveError.httpStatus(-1)
            }
            return SpotifyCredentials.Attempt(body: body, http: http, request: request)
        }
        guard sent.status == 200 else { throw StorageResolveError.httpStatus(sent.status) }

        let decoded = StorageResolveResponse(protobuf: sent.body)
        guard decoded.result == .cdn else { throw StorageResolveError.notServedFromCDN }
        guard let usable = CDNURLExpiry.usableURLs(decoded.cdnURLs, now: now()).first else {
            throw StorageResolveError.noUsableURL
        }
        return usable
    }
}
