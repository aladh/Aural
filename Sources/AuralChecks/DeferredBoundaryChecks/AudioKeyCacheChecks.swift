import AuralDomain
import Foundation
@testable import AuralCore

/// `AudioKeyCache` caches a successful audio-key response per file id and never caches a
/// failure. Stage 1 scaffolding for #201/#208: nothing consumes the cache yet.
@MainActor
func runAudioKeyCacheChecks(_ check: CheckRunner) {
    check.suite("A second request for the same file id does not hit the provider") {
        let trackGID = [UInt8](repeating: 1, count: 16)
        let fileA = [UInt8](repeating: 0xA, count: 20)
        let fileB = [UInt8](repeating: 0xB, count: 20)
        let keyA = (0..<16).map { UInt8($0) }
        let keyB = (16..<32).map { UInt8($0) }

        let provider = ScriptedAudioKeyProvider()
        provider.setResult(.success(keyA), forFileID: fileA)
        provider.setResult(.success(keyB), forFileID: fileB)
        let cache = AudioKeyCache(provider: provider)

        let first = successValue(cache.key(trackGID: trackGID, fileID: fileA))
        check.equal("first request for file A returns its key", first, keyA)
        check.equal("first request for file A hits the provider", provider.callCount, 1)

        let second = successValue(cache.key(trackGID: trackGID, fileID: fileA))
        check.equal("second request for file A is cached", second, keyA)
        check.equal("second request for file A does not hit the provider", provider.callCount, 1)

        let differentFile = successValue(cache.key(trackGID: trackGID, fileID: fileB))
        check.equal("a different file id returns its own key", differentFile, keyB)
        check.equal("a different file id hits the provider", provider.callCount, 2)
    }

    check.suite("A failure is never cached") {
        let trackGID = [UInt8](repeating: 1, count: 16)
        let fileID = [UInt8](repeating: 0xC, count: 20)

        let provider = ScriptedAudioKeyProvider(defaultResult: .failure(.notConnected))
        let cache = AudioKeyCache(provider: provider)

        check.equal(
            "the failure is reported",
            failureValue(cache.key(trackGID: trackGID, fileID: fileID)),
            .notConnected
        )
        check.equal("the failure hits the provider", provider.callCount, 1)

        check.equal(
            "a second call after a failure hits the provider again, not the cache",
            failureValue(cache.key(trackGID: trackGID, fileID: fileID)),
            .notConnected
        )
        check.equal("the retry reaches the provider", provider.callCount, 2)

        let key = [UInt8](repeating: 9, count: 16)
        provider.setResult(.success(key), forFileID: fileID)
        check.equal(
            "a subsequent success is returned",
            successValue(cache.key(trackGID: trackGID, fileID: fileID)),
            key
        )
        check.equal("the subsequent success hits the provider", provider.callCount, 3)

        check.equal(
            "the success is now cached",
            successValue(cache.key(trackGID: trackGID, fileID: fileID)),
            key
        )
        check.equal("the cached success does not hit the provider again", provider.callCount, 3)
    }

    check.suite("An invalid identifier is rejected and never cached") {
        // Length validation lives in `PlaybackCore.audioKey`, which cannot run without the
        // C module; here the scripted provider stands in for that rejection so the cache's
        // own "never cache a failure" behavior is covered at this boundary too.
        let shortTrackGID = [UInt8](repeating: 1, count: 8)
        let fileID = [UInt8](repeating: 0xD, count: 20)

        let provider = ScriptedAudioKeyProvider(defaultResult: .failure(.invalidIdentifier))
        let cache = AudioKeyCache(provider: provider)

        check.equal(
            "an invalid identifier is reported",
            failureValue(cache.key(trackGID: shortTrackGID, fileID: fileID)),
            .invalidIdentifier
        )
        check.equal("an invalid identifier is not cached", provider.callCount, 1)

        _ = cache.key(trackGID: shortTrackGID, fileID: fileID)
        check.equal("retrying an invalid identifier hits the provider again", provider.callCount, 2)
    }
}

private func successValue(_ result: Swift.Result<[UInt8], AudioKeyError>) -> [UInt8]? {
    if case let .success(key) = result { return key }
    return nil
}

private func failureValue(_ result: Swift.Result<[UInt8], AudioKeyError>) -> AudioKeyError? {
    if case let .failure(error) = result { return error }
    return nil
}

/// Stands in for `RustPlaybackEngine.audioKey`. Records every call and returns a
/// per-file-id scripted result, or `defaultResult` when none was set for that file id.
private final class ScriptedAudioKeyProvider: AudioKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let defaultResult: Swift.Result<[UInt8], AudioKeyError>
    private var results: [Data: Swift.Result<[UInt8], AudioKeyError>] = [:]
    private var storedCallCount = 0

    init(defaultResult: Swift.Result<[UInt8], AudioKeyError> = .failure(.engineFailure(-1))) {
        self.defaultResult = defaultResult
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    func setResult(_ result: Swift.Result<[UInt8], AudioKeyError>, forFileID fileID: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        results[Data(fileID)] = result
    }

    func audioKey(trackGID: [UInt8], fileID: [UInt8]) -> Swift.Result<[UInt8], AudioKeyError> {
        lock.lock()
        defer { lock.unlock() }
        storedCallCount += 1
        return results[Data(fileID)] ?? defaultResult
    }
}
