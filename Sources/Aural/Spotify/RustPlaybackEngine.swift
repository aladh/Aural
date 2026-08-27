import AuralDomain
import Foundation

/// A typed control event emitted by the embedded engine. PCM deliberately bypasses this stream
/// and continues directly to `AudioRenderer` on the decoder callback thread.
nonisolated enum RustPlaybackEvent: Sendable {
    case playback(RustPlaybackState)
    case queue(RustQueueState)
    case connection(RustConnectionState)
    case devices(RustDevicesState)
}

/// Process-local ordering assigned at callback intake. Backend revisions remain authoritative
/// within a source; this sequence makes cross-callback delivery deterministic in Swift.
nonisolated struct RustPlaybackEventEnvelope: Sendable {
    let sequence: UInt64
    let receivedAt: Date
    let event: RustPlaybackEvent
}

/// The one embedded playback engine owned by this process.
///
/// The C ABI exposes process-global callbacks, so an instance-per-view abstraction would be
/// dishonest. This adapter makes the process lifetime explicit, registers once, and fans typed
/// events into AsyncStreams without retaining a controller or using unsafe mutable globals.
nonisolated final class RustPlaybackEngine: LocalPlaybackEngine, @unchecked Sendable {
    static let shared = RustPlaybackEngine()

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RustPlaybackEventEnvelope>.Continuation] = [:]
    private var callbacksRegistered = false
    private var sequence: UInt64 = 0

    private init() {}

    func authorizeStreaming(with accessToken: String) -> Int32 {
        PlaybackCore.authorizeStreaming(with: accessToken)
    }

    func initialize() -> PlaybackEngineResult {
        engineResult(PlaybackCore.initialize())
    }

    func execute(_ operation: LocalPlaybackOperation) -> PlaybackEngineResult {
        switch operation {
        case let .playURI(uri): engineResult(PlaybackCore.play(uri: uri))
        case let .playTracks(tracks): engineResult(PlaybackCore.play(tracks: tracks))
        case .pause: engineResult(PlaybackCore.pause())
        case .resume: engineResult(PlaybackCore.resume())
        case .next: engineResult(PlaybackCore.next())
        case .previous: engineResult(PlaybackCore.previous())
        case let .seek(milliseconds): engineResult(PlaybackCore.seek(to: milliseconds))
        case let .shuffle(enabled): engineResult(PlaybackCore.setShuffle(enabled))
        case let .repeatOptions(context, track, rollbackContext, rollbackTrack):
            executeRepeat(
                context: context,
                track: track,
                rollbackContext: rollbackContext,
                rollbackTrack: rollbackTrack
            )
        case let .addToQueue(uri): engineResult(PlaybackCore.addToQueue(uri: uri))
        case .transferToLocal: engineResult(PlaybackCore.transferToLocal())
        case let .transferToDevice(id): engineResult(PlaybackCore.transferPlayback(to: id))
        }
    }

    func positionMilliseconds() -> UInt32 { PlaybackCore.positionMilliseconds() }
    func queueSnapshotJSON() -> String? { PlaybackCore.queueSnapshotJSON() }
    func configureHighQualityPlayback() { PlaybackCore.configureHighQualityPlayback() }
    func shutdown() -> PlaybackEngineResult {
        engineResult(PlaybackCore.shutdown())
    }
    func cleanup() { PlaybackCore.cleanup() }
    func clearStreamingCredentials() { PlaybackCore.clearStreamingCredentials() }
    func disconnect() -> PlaybackEngineResult {
        engineResult(PlaybackCore.disconnect())
    }
    func forceReconnect() -> Int32 { PlaybackCore.forceReconnect() }

    /// Copies a non-optional FFI result into the Swift engine wrapper. Do not reconstruct
    /// `PlaybackCore.Result` from `PlaybackEngineResult.rawValue`: the imported open C enum
    /// has a failable raw-value initializer.
    private func engineResult(_ result: PlaybackCore.Result) -> PlaybackEngineResult {
        PlaybackEngineResult(rawValue: result.rawValue)
    }

    private func executeRepeat(
        context: Bool,
        track: Bool,
        rollbackContext: Bool,
        rollbackTrack: Bool
    ) -> PlaybackEngineResult {
        RepeatTransitionApplication.apply(
            .planning(
                from: RepeatFlags(context: rollbackContext, track: rollbackTrack),
                to: RepeatFlags(context: context, track: track)
            ),
            setContext: { engineResult(PlaybackCore.setRepeat(context: $0)) },
            setTrack: { engineResult(PlaybackCore.setRepeatTrack($0)) }
        )
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.continuations[id] = nil }
            }
            // Install the continuation before registration. This closes the initial-event loss
            // window if callback registration ever publishes a snapshot synchronously.
            registerCallbacksIfNeeded()
        }
    }

    private func registerCallbacksIfNeeded() {
        let shouldRegister = lock.withLock { () -> Bool in
            guard !callbacksRegistered else { return false }
            callbacksRegistered = true
            return true
        }
        guard shouldRegister else { return }

        PlaybackCore.registerAudioDataCallback { samples, count in
            guard let samples else { return }
            try? auralAudioRendererResult.get().writeAudioData(samples, count: count)
        }
        PlaybackCore.registerAudioControlCallback { event in
            guard let renderer = try? auralAudioRendererResult.get() else { return }
            switch event {
            case .stop: renderer.stop()
            case .start: renderer.start()
            case .clear: renderer.flush()
            @unknown default: break
            }
        }
        PlaybackCore.registerPlaybackStateCallback { pointer in
            RustPlaybackEngine.shared.decodeAndEmit(pointer, as: RustPlaybackState.self) {
                .playback($0)
            }
        }
        PlaybackCore.registerQueueCallback { pointer in
            RustPlaybackEngine.shared.decodeAndEmit(pointer, as: RustQueueState.self) {
                .queue($0)
            }
        }
        PlaybackCore.registerConnectionStateCallback { pointer in
            RustPlaybackEngine.shared.decodeAndEmit(pointer, as: RustConnectionState.self) {
                .connection($0)
            }
        }
        PlaybackCore.registerDevicesCallback { pointer in
            RustPlaybackEngine.shared.decodeAndEmit(pointer, as: RustDevicesState.self) {
                .devices($0)
            }
        }
    }

    private func decodeAndEmit<T: Decodable & Sendable>(
        _ pointer: UnsafePointer<CChar>?,
        as type: T.Type,
        event: (T) -> RustPlaybackEvent
    ) {
        guard let pointer, let data = String(cString: pointer).data(using: .utf8) else { return }
        do {
            emit(event(try JSONDecoder().decode(type, from: data)))
        } catch {
            debugLog(
                "RustPlaybackEngine",
                "callback payload did not decode as \(type): \(error.localizedDescription)"
            )
        }
    }

    private func emit(_ event: RustPlaybackEvent) {
        let (envelope, targets) = lock.withLock {
            sequence &+= 1
            let envelope = RustPlaybackEventEnvelope(
                sequence: sequence,
                receivedAt: Date(),
                event: event
            )
            return (envelope, Array(continuations.values))
        }
        for continuation in targets {
            continuation.yield(envelope)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
