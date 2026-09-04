//
//  SpotifyAudioSourceProvider.swift
//  Aural
//
//  Turns one (track GID, file id) pair into a readable, decrypted byte source: the AES key from
//  the AP session, the CDN URL from spclient's storage-resolve, and a `RangedAudioFetcher` over
//  that URL.
//
//  The key request is cached per file id and never retried in a loop. Spotify has throttled
//  audio-key requests since 2025, and a retry loop is exactly what gets an account rate-limited;
//  a failure is reported as an unplayable track instead, which Spirc turns into a skip.
//

import AuralDomain
import Foundation

/// The audio-key request, as the provider needs it. Injected so checks never touch the C
/// boundary and so `PlaybackCore` stays the only importer of it.
typealias AudioKeyRequesting = @Sendable ([UInt8], [UInt8]) -> Swift.Result<[UInt8], AudioKeyError>

enum SpotifyAudioSourceError: Error, Sendable, Equatable {
    /// The key request failed. Carries no key material and no engine detail beyond the reason.
    case audioKeyUnavailable
    case invalidCDNURL
}

/// Builds `SpotifyTrackByteSource`s for the Swift audio path.
actor SpotifyAudioSourceProvider: AudioTrackByteSourceProviding {
    private let requestAudioKey: AudioKeyRequesting
    private let storageResolve: StorageResolveClient
    private let transport: any RangedHTTPTransport

    /// Successful keys, by file id. A file's key does not change, and re-requesting it is what
    /// the throttle punishes. Never holds a failure: a failed key is retried on the next load,
    /// which is a user action, not a loop.
    private var keys: [Data: [UInt8]] = [:]

    init(
        requestAudioKey: @escaping AudioKeyRequesting,
        storageResolve: StorageResolveClient = StorageResolveClient(),
        transport: any RangedHTTPTransport = URLSessionRangedTransport()
    ) {
        self.requestAudioKey = requestAudioKey
        self.storageResolve = storageResolve
        self.transport = transport
    }

    func makeSource(
        trackGID: [UInt8],
        fileID: [UInt8],
        format: SpotifyAudioFormat
    ) async throws -> any AudioTrackByteSource {
        // Resolved in parallel: the key comes from the AP session and the URL from spclient, so
        // neither waits on the other. #208 asks for exactly this overlap.
        async let url = storageResolve.resolve(fileID: fileID)
        let key = try await audioKey(trackGID: trackGID, fileID: fileID)
        let fetcher = RangedAudioFetcher(url: try await url, transport: transport)
        return SpotifyTrackByteSource(fetcher: fetcher, key: key, format: format)
    }

    /// The cached key for `fileID`, or one fresh request for it. Runs the blocking C call off
    /// the cooperative pool: librespot bounds a single request at 1500 ms, which is far too long
    /// to park a concurrency thread on.
    private func audioKey(trackGID: [UInt8], fileID: [UInt8]) async throws -> [UInt8] {
        let cacheKey = Data(fileID)
        if let cached = keys[cacheKey] { return cached }

        let request = requestAudioKey
        let result = await Task.detached(priority: .userInitiated) {
            request(trackGID, fileID)
        }.value

        switch result {
        case let .success(key):
            keys[cacheKey] = key
            return key
        case let .failure(reason):
            debugLog("SpotifyAudioSourceProvider", "Audio key unavailable: \(reason)")
            throw SpotifyAudioSourceError.audioKeyUnavailable
        }
    }
}
