//
//  SpotifyTrackByteSource.swift
//  Aural
//
//  Joins the Stage 1 building blocks into the one seam the decode path actually reads through:
//  ranged CDN fetch (`RangedAudioFetcher`) plus AES-128-CTR decrypt (`AESCTRDecryptor`) behind
//  `DecodeByteSource` (`VorbisDecodePipeline`'s input) and `OggByteReader` (`OggSeeker`'s input).
//
//  Offsets are file offsets in the *decrypted* file, which is also the encrypted file's offset
//  space: CTR is a stream cipher, so plaintext and ciphertext are the same length and byte n of
//  one is byte n of the other. That is what makes a ranged read decryptable on its own, with the
//  counter advanced to `offset / 16` and the leading `offset % 16` keystream bytes discarded.
//

import AuralDomain
import Foundation

/// What can go wrong reading a track's bytes, as a closed set with nothing borrowed from the
/// underlying error's description. The CDN URL carries a signed `__token__`/`verify` query, and
/// these values reach logs and (through `.unavailable`) Spotify Connect.
enum SpotifyTrackByteSourceError: Error, Sendable, Equatable {
    case fetchFailed
    case decryptFailed
    /// The CDN refused the pre-signed URL (403). A live path re-resolves; Stage 1 reports it.
    case urlExpired
}

/// One decrypted Spotify audio file, read by byte range.
///
/// An actor rather than a lock: every read is `await`ed from `VorbisDecodePipeline`'s bridging
/// `Task` or from `OggSeeker`, never from a real-time thread, and the fetcher it wraps is itself
/// an actor. Decryption happens per read with a fresh cryptor seeked to the read's offset, so no
/// cipher state is shared between concurrent reads.
actor SpotifyTrackByteSource {
    /// Byte offset of the Ogg capture pattern in a decrypted Spotify audio file: the fixed-size
    /// normalisation header comes first.
    static let oggStartOffset = SpotifyAudioHeader.length

    /// Seconds of audio kept downloaded ahead of the play position, matching librespot's
    /// read-ahead. Not adaptive; #208 records ping-based tuning as a later refinement.
    private static let readAheadSeconds = 5

    private let fetcher: RangedAudioFetcher
    private let key: [UInt8]
    private let format: SpotifyAudioFormat

    init(fetcher: RangedAudioFetcher, key: [UInt8], format: SpotifyAudioFormat) {
        self.fetcher = fetcher
        self.key = key
        self.format = format
    }

    /// The file's total length once the first fetch has learned it from `Content-Range`.
    /// Triggers that fetch if it has not happened yet.
    func totalLength() async throws -> Int {
        if let known = await fetcher.length { return known }
        do {
            return try await fetcher.open()
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Downloads whatever of the file is still missing.
    ///
    /// This is what gates `TimeToPreloadNext`: telling Spirc to preload the next track while
    /// this one is still pulling bytes would put two downloads in flight over one connection,
    /// so the report waits for this rather than firing on the clock alone.
    func downloadFully() async throws {
        let length = try await totalLength()
        guard length > 0 else { return }
        do {
            try await fetcher.prefetch(from: 0, upTo: length - 1)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Fetches `readAheadSeconds` of audio past `positionMs`, so the decode loop's next read is
    /// usually already in the store.
    ///
    /// The byte offset is derived from the format's constant bitrate rather than from the Ogg
    /// page stream: this only decides what to download early, so an approximation that is off by
    /// a page costs nothing, and a real page walk would cost the read it is meant to avoid.
    /// Failures are swallowed — the read that actually needs the bytes reports its own.
    func prefetchAhead(ofPositionMs positionMs: UInt32) async {
        guard let bytesPerSecond = format.bytesPerSecond else { return }
        let played = Int(positionMs / 1_000) * bytesPerSecond
        let offset = Self.oggStartOffset + played
        try? await fetcher.prefetch(from: offset, upTo: offset + bytesPerSecond * Self.readAheadSeconds)
    }

    private func decryptedRead(offset: Int, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        let total = try await totalLength()
        guard offset < total else { return Data() }

        let encrypted: Data
        do {
            encrypted = try await fetcher.read(offset: offset, length: length)
        } catch {
            throw Self.mapped(error)
        }
        guard !encrypted.isEmpty else { return Data() }
        do {
            return try AESCTRDecryptor.decrypt(key: key, offset: UInt64(offset), data: encrypted)
        } catch {
            throw SpotifyTrackByteSourceError.decryptFailed
        }
    }

    /// Maps a fetcher error onto this type's closed set. `.invalidRange` past the end of the
    /// file is not modelled as a failure — the callers above turn it into an empty read, which
    /// is how both `DecodeByteSource` and `OggByteReader` spell "end of file".
    private static func mapped(_ error: Error) -> SpotifyTrackByteSourceError {
        switch error {
        case RangedAudioFetcherError.forbidden: .urlExpired
        default: .fetchFailed
        }
    }
}

extension SpotifyTrackByteSource: DecodeByteSource {
    /// A read past the end of the file returns fewer bytes (or none), which is exactly the
    /// exhaustion signal `VorbisDecodePipeline` looks for.
    nonisolated func read(offset: Int, length: Int) async throws -> Data {
        try await decryptedRead(offset: offset, length: length)
    }

    nonisolated var length: Int? {
        get async { try? await totalLength() }
    }
}

extension SpotifyTrackByteSource: AudioTrackByteSource {}
