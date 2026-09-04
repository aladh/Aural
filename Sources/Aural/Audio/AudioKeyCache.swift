import Foundation

/// Caches successful AP audio-key responses by file id, for the lifetime of the process.
///
/// Spotify rate-limits key requests, so each file id must be requested at most once per
/// process rather than once per playback attempt. A failure (invalid identifier, not
/// connected, timeout, or any other engine failure) is never cached: the underlying
/// condition may clear, and caching it would turn a transient failure into a permanent one
/// for the rest of the session.
nonisolated final class AudioKeyCache: @unchecked Sendable {
    private let provider: any AudioKeyProviding
    private let lock = NSLock()
    private var cache: [Data: [UInt8]] = [:]

    init(provider: any AudioKeyProviding) {
        self.provider = provider
    }

    /// Returns the key already cached for `fileID`, or requests one from `provider` and
    /// caches it only on success.
    func key(trackGID: [UInt8], fileID: [UInt8]) -> Swift.Result<[UInt8], AudioKeyError> {
        let fileKey = Data(fileID)

        lock.lock()
        let cached = cache[fileKey]
        lock.unlock()
        if let cached { return .success(cached) }

        let result = provider.audioKey(trackGID: trackGID, fileID: fileID)
        if case let .success(key) = result {
            lock.lock()
            cache[fileKey] = key
            lock.unlock()
        }
        return result
    }
}
