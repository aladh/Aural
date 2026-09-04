//
//  SpotifyTrackByteSource.swift
//  Spotty
//
//  Joins the Stage 1 building blocks into the one seam the decode path reads through: ranged CDN
//  fetch (`RangedAudioFetcher`) plus AES-128-CTR decrypt (`AESCTRDecryptor`) behind
//  `DecodeByteSource` (`VorbisDecodePipeline`'s input) and, asynchronously, `OggSeeker`'s reader.
//
//  Offsets are file offsets in the *decrypted* file, which is also the encrypted file's offset
//  space: CTR is a stream cipher, so plaintext and ciphertext are the same length and byte n of
//  one is byte n of the other. That is what makes a ranged read decryptable on its own, with the
//  counter advanced to `offset / 16` and the leading `offset % 16` keystream bytes discarded.
//
//  `DecodeByteSource.read` is synchronous, and the fetcher underneath is an actor, so this type
//  owns the bridge between them -- and, per that seam's contract, the timeout on it. The bridge
//  lives here rather than in the pipeline precisely because the deadline is a property of the
//  network fetch, not of the decode loop.
//

import SpottyDomain
import Foundation

/// What can go wrong reading a track's bytes, as a closed set with nothing borrowed from the
/// underlying error's description. The CDN URL carries a signed `__token__`/`verify` query, and
/// these values reach logs and (through `.unavailable`) Spotify Connect.
enum SpotifyTrackByteSourceError: Error, Sendable, Equatable {
    case fetchFailed
    case decryptFailed
    /// The CDN refused the pre-signed URL (403). A live path re-resolves; Stage 1 reports it.
    case urlExpired
    /// A blocking read did not complete within `readTimeout`. The decode thread is freed rather
    /// than parked forever on a fetch that has stalled.
    case timedOut
}

/// One decrypted Spotify audio file, read by byte range.
///
/// `@unchecked Sendable`: the only mutable state is `cachedLength`, guarded by `lock`. Everything
/// else is immutable, and `RangedAudioFetcher` is an actor that serializes its own store.
/// Decryption creates a fresh cryptor seeked to each read's offset, so no cipher state is shared.
final class SpotifyTrackByteSource: @unchecked Sendable {
    /// Byte offset of the Ogg capture pattern in a decrypted Spotify audio file: the fixed-size
    /// normalisation header comes first.
    static let oggStartOffset = SpotifyAudioHeader.length

    /// Deadline on one blocking read. Long enough to cover a slow chunk plus the fetcher's own
    /// bounded 429 retries, short enough that a wedged fetch ends the track instead of the app.
    private static let readTimeout: DispatchTimeInterval = .seconds(30)

    /// Seconds of audio kept downloaded ahead of the play position, matching librespot's
    /// read-ahead. Not adaptive; #208 records ping-based tuning as a later refinement.
    private static let readAheadSeconds = 5

    private let fetcher: RangedAudioFetcher
    private let key: [UInt8]
    private let format: SpotifyAudioFormat

    private let lock = NSLock()
    private var cachedLength: Int?

    init(fetcher: RangedAudioFetcher, key: [UInt8], format: SpotifyAudioFormat) {
        self.fetcher = fetcher
        self.key = key
        self.format = format
    }

    /// The file's total length once the first fetch has learned it from `Content-Range`.
    /// Triggers that fetch if it has not happened yet.
    func totalLength() async throws -> Int {
        if let known = lock.withLock({ cachedLength }) { return known }
        if let known = await fetcher.length {
            lock.withLock { cachedLength = known }
            return known
        }
        do {
            let length = try await fetcher.open()
            lock.withLock { cachedLength = length }
            return length
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Downloads whatever of the file is still missing.
    ///
    /// This is what gates `TimeToPreloadNext`: telling Spirc to preload the next track while this
    /// one is still pulling bytes would put two downloads in flight over one connection, so the
    /// report waits for this rather than firing on the clock alone.
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
    /// a page costs nothing, while a real page walk would cost the read it is meant to avoid.
    /// Failures are swallowed -- the read that actually needs the bytes reports its own.
    func prefetchAhead(ofPositionMs positionMs: UInt32) async {
        guard let bytesPerSecond = format.bytesPerSecond else { return }
        let played = Int(positionMs / 1_000) * bytesPerSecond
        let offset = Self.oggStartOffset + played
        try? await fetcher.prefetch(from: offset, upTo: offset + bytesPerSecond * Self.readAheadSeconds)
    }

    /// The decrypted bytes at `offset..<offset+length`, fetching whatever is missing. A read at
    /// or past the end of the file returns empty, which is how both seams spell exhaustion.
    func readRange(offset: Int, length: Int) async throws -> Data {
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

    /// Runs one async read to completion on a detached task and parks the calling thread on it,
    /// bounded by `readTimeout`. Only ever called from `VorbisDecodePipeline`'s decode thread,
    /// which exists to be blocked; calling it from the cooperative pool would burn a thread.
    private func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingReadBox<T>()
        Task.detached(priority: .userInitiated) {
            do {
                box.value = .success(try await work())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.readTimeout) == .success else {
            throw SpotifyTrackByteSourceError.timedOut
        }
        switch box.value {
        case let .success(value): return value
        case let .failure(error): throw error
        case .none: throw SpotifyTrackByteSourceError.fetchFailed
        }
    }

    /// Maps a fetcher error onto this type's closed set. `.invalidRange` past the end of the file
    /// is not modelled as a failure -- the callers above turn it into an empty read.
    private static func mapped(_ error: Error) -> SpotifyTrackByteSourceError {
        switch error {
        case RangedAudioFetcherError.forbidden: .urlExpired
        default: .fetchFailed
        }
    }
}

/// Carries a blocking read's result across the semaphore: the writer (the detached task) and the
/// reader (the decode thread after `wait`) never touch it concurrently.
private final class BlockingReadBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

extension SpotifyTrackByteSource: AudioTrackByteSource {
    /// `DecodeByteSource`'s synchronous read, bridged onto the async fetcher with this type's own
    /// deadline. See the file header for why the bridge belongs here.
    func read(offset: Int, length: Int) throws -> Data {
        try blocking { [self] in try await readRange(offset: offset, length: length) }
    }

    /// Known only after the first fetch. The pipeline treats `nil` as "not known yet" and reads
    /// until exhaustion, so an unopened file is not a failure here.
    var length: Int? { lock.withLock { cachedLength } }
}
