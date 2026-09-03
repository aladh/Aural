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

/// Process-local ordering assigned at callback intake and delivered in that order.
/// Backend revisions remain authoritative within a source; this sequence makes
/// cross-callback delivery deterministic in Swift.
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
    private let fanout = EngineEventFanout(clock: SystemPlaybackClock())
    private var callbacksRegistered = false

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
        case let .resume(plan): resume(plan)
        case .next: engineResult(PlaybackCore.next())
        case .previous: engineResult(PlaybackCore.previous())
        case let .seek(milliseconds): engineResult(PlaybackCore.seek(to: milliseconds))
        case let .shuffle(enabled): engineResult(PlaybackCore.setShuffle(enabled))
        case let .repeatOptions(plan): executeRepeat(plan)
        case let .addToQueue(uri): engineResult(PlaybackCore.addToQueue(uri: uri))
        case .transferToLocal: engineResult(PlaybackCore.transferToLocal())
        case let .transferToDevice(id): engineResult(PlaybackCore.transferPlayback(to: id))
        }
    }

    func positionMilliseconds() -> UInt32 { PlaybackCore.positionMilliseconds() }
    func resumePositionMilliseconds() -> UInt32 { PlaybackCore.resumePositionMilliseconds() }
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

    /// Activate/`play()` first. On a non-reconnect failure, iterate Swift load targets.
    /// `PlaybackCoordinator` serializes this whole operation.
    private func resume(_ plan: ResumeLoadPlan) -> PlaybackEngineResult {
        let play = engineResult(PlaybackCore.resume())
        if play.isOK || play.requiresReconnect { return play }
        for target in plan.targets() {
            let loaded = engineResult(PlaybackCore.load(target))
            if loaded.isOK || loaded.requiresReconnect { return loaded }
        }
        return play
    }

    /// Copies a non-optional FFI result into the Swift engine wrapper. Do not reconstruct
    /// `PlaybackCore.Result` from `PlaybackEngineResult.rawValue`: the imported open C enum
    /// has a failable raw-value initializer.
    private func engineResult(_ result: PlaybackCore.Result) -> PlaybackEngineResult {
        PlaybackEngineResult(rawValue: result.rawValue)
    }

    private func executeRepeat(_ plan: RepeatTransitionPlan) -> PlaybackEngineResult {
        RepeatTransitionApplication.apply(plan) { mutation in
            switch mutation.flag {
            case .context: engineResult(PlaybackCore.setRepeat(context: mutation.enabled))
            case .track: engineResult(PlaybackCore.setRepeatTrack(mutation.enabled))
            }
        }
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        // Install the continuation before registration. This closes the initial-event loss
        // window if callback registration ever publishes a snapshot synchronously.
        fanout.events { [self] in
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
        fanout.emit(event)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
