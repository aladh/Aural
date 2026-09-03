@preconcurrency import AppKit
import AuralDomain
import Foundation

nonisolated struct PlaybackEngineResult: Equatable, Sendable {
    let rawValue: Int32

    static let ok = PlaybackEngineResult(rawValue: 0)
    static let error = PlaybackEngineResult(rawValue: -1)
    var isOK: Bool { rawValue == 0 }
    var requiresReconnect: Bool { rawValue == -2 || rawValue == -3 }
}

/// Play first; on a non-reconnect failure, try each resume-load target until one lands.
nonisolated enum UserResumeLoadSequence {
    static func completing(
        play: PlaybackEngineResult,
        targets: [ResumeLoadPlan.Target],
        load: (ResumeLoadPlan.Target) -> PlaybackEngineResult
    ) -> PlaybackEngineResult {
        if play.isOK || play.requiresReconnect { return play }
        for target in targets {
            let loaded = load(target)
            if loaded.isOK || loaded.requiresReconnect { return loaded }
        }
        return play
    }
}

nonisolated enum LocalPlaybackOperation: Sendable {
    case playURI(String)
    case playTracks([String])
    case pause
    case resume(ResumeLoadPlan)
    case next
    case previous
    case seek(UInt32)
    case shuffle(Bool)
    case repeatOptions(RepeatTransitionPlan)
    case addToQueue(String)
    case transferToLocal
    case transferToDevice(String)
}

nonisolated protocol LocalPlaybackEngine: Sendable {
    func events() -> AsyncStream<RustPlaybackEventEnvelope>
    func authorizeStreaming(with accessToken: String) -> Int32
    func initialize() -> PlaybackEngineResult
    func execute(_ operation: LocalPlaybackOperation) -> PlaybackEngineResult
    func positionMilliseconds() -> UInt32
    func resumePositionMilliseconds() -> UInt32
    func resumeContextURI() -> String?
    func resumeTrackURI() -> String?
    func queueSnapshot() -> RustQueueState?
    func configureHighQualityPlayback()
    func shutdown() -> PlaybackEngineResult
    func cleanup()
    func clearStreamingCredentials()
    func disconnect() -> PlaybackEngineResult
    func forceReconnect() -> Int32
}

extension LocalPlaybackEngine {
    func resumePositionMilliseconds() -> UInt32 { 0 }
    func resumeContextURI() -> String? { nil }
    func resumeTrackURI() -> String? { nil }
    func queueSnapshot() -> RustQueueState? { nil }
}

nonisolated protocol RemotePlaybackClient: Sendable {
    func send(_ command: SpotifyConnectCommand, from sourceID: String, to targetID: String) async throws
    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata
}

extension SpotifyConnectAPI: RemotePlaybackClient {}

/// Account-scoped metadata requests are shared by Now Playing and queue hydration. The actor
/// coalesces identical in-flight requests and retains only a bounded cache for the current account.
actor TrackMetadataService {
    private static let cacheLimit = 512

    private let remote: any RemotePlaybackClient
    private var cache: [String: SpotifyConnectTrackMetadata] = [:]
    private var inFlight: [String: Task<SpotifyConnectTrackMetadata, any Error>] = [:]

    init(remote: any RemotePlaybackClient) {
        self.remote = remote
    }

    func metadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        if let cached = cache[uri] { return cached }
        if let task = inFlight[uri] { return try await task.value }

        let task = Task { [remote] in try await remote.trackMetadata(for: uri) }
        inFlight[uri] = task
        do {
            let value = try await task.value
            inFlight[uri] = nil
            cache[uri] = value
            trimCache(preserving: uri)
            return value
        } catch {
            inFlight[uri] = nil
            throw error
        }
    }

    func reset() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll(keepingCapacity: false)
        cache.removeAll(keepingCapacity: false)
    }

    private func trimCache(preserving uri: String) {
        guard cache.count > Self.cacheLimit else { return }
        for key in cache.keys where key != uri {
            cache[key] = nil
            if cache.count <= Self.cacheLimit { break }
        }
    }
}

nonisolated protocol WebQueueClient: Sendable {
    func queue() async throws -> [CatalogTrack]
}

extension SpotifyWebPlayerAPI: WebQueueClient {}

nonisolated protocol AccountSession: Sendable {
    func authorizeInteractively() async throws -> KeymasterTokens
    func hasGrant() async -> Bool
    func accessToken() async throws -> String
    func adopt(_ tokens: KeymasterTokens) async throws
    func clear() async
    func revocations() -> AsyncStream<Void>
}

nonisolated struct LiveAccountSession: AccountSession {
    func authorizeInteractively() async throws -> KeymasterTokens { try await KeymasterAuth.authorize() }
    func hasGrant() async -> Bool { await KeymasterSession.shared.hasGrant }
    func accessToken() async throws -> String { try await KeymasterSession.shared.accessToken() }
    func adopt(_ tokens: KeymasterTokens) async throws { try await KeymasterSession.shared.adopt(tokens) }
    func clear() async { await KeymasterSession.shared.clear() }
    func revocations() -> AsyncStream<Void> { KeymasterSession.shared.grantRevocations() }
}

nonisolated protocol AudioOutputPreparing: Sendable {
    func prepareForPlayback() throws
}

nonisolated struct LiveAudioOutput: AudioOutputPreparing {
    func prepareForPlayback() throws {
        try auralAudioRendererResult.get().setVolume(1)
    }
}

nonisolated protocol PlaybackPreferences: Sendable {
    func shuffleEnabled() async -> Bool
    func setShuffleEnabled(_ enabled: Bool) async
    func lastRemoteDeviceID() async -> String?
    func setLastRemoteDeviceID(_ id: String?) async
    func shuffleHistory() async -> [String: TimeInterval]
    func setShuffleHistory(_ history: [String: TimeInterval]) async
}

nonisolated final class UserDefaultsPlaybackPreferences: PlaybackPreferences, @unchecked Sendable {
    static let shared = UserDefaultsPlaybackPreferences()

    private enum Key {
        static let shuffle = "playback.shuffle.fewer-repeats"
        static let remoteDevice = "playback.last-remote-device-id"
        static let history = "playback.fewer-repeats.history"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shuffleEnabled() -> Bool { lock.withCriticalSection { defaults.bool(forKey: Key.shuffle) } }

    func setShuffleEnabled(_ enabled: Bool) {
        lock.withCriticalSection { defaults.set(enabled, forKey: Key.shuffle) }
    }

    func lastRemoteDeviceID() -> String? {
        lock.withCriticalSection { defaults.string(forKey: Key.remoteDevice) }
    }

    func setLastRemoteDeviceID(_ id: String?) {
        if let id {
            lock.withCriticalSection { defaults.set(id, forKey: Key.remoteDevice) }
        } else {
            lock.withCriticalSection { defaults.removeObject(forKey: Key.remoteDevice) }
        }
    }

    func shuffleHistory() -> [String: TimeInterval] {
        guard
            let data = lock.withCriticalSection({ defaults.data(forKey: Key.history) }),
            let history = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return [:] }
        return history
    }

    func setShuffleHistory(_ history: [String: TimeInterval]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        lock.withCriticalSection { defaults.set(data, forKey: Key.history) }
    }
}

nonisolated enum SystemLifecycleEvent: Sendable {
    case willSleep
    case didWake
}

nonisolated protocol SystemLifecycleEvents: Sendable {
    func events() -> AsyncStream<SystemLifecycleEvent>
}

nonisolated protocol PlaybackClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

nonisolated struct SystemPlaybackClock: PlaybackClock {
    func now() -> Date { Date() }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Adapts AppKit notifications once at the infrastructure edge. Product stores consume a typed
/// AsyncSequence and do not own NotificationCenter tokens.
nonisolated final class MacSystemLifecycleEvents: SystemLifecycleEvents, @unchecked Sendable {
    static let shared = MacSystemLifecycleEvents()

    private init() {}

    func events() -> AsyncStream<SystemLifecycleEvent> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let sleep = center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { _ in continuation.yield(.willSleep) }
            let wake = center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in continuation.yield(.didWake) }
            let tokens = LifecycleObserverTokens(center: center, tokens: [sleep, wake])
            continuation.onTermination = { _ in tokens.cancel() }
        }
    }
}

nonisolated private final class LifecycleObserverTokens: @unchecked Sendable {
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]
    private let lock = NSLock()
    private var cancelled = false

    init(center: NotificationCenter, tokens: [NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    func cancel() {
        lock.withCriticalSection {
            guard !cancelled else { return }
            cancelled = true
            for token in tokens { center.removeObserver(token) }
        }
    }
}

private extension NSLock {
    func withCriticalSection<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Production dependencies are visible in one composition value rather than constructed inside
/// feature methods. Tests can substitute a complete coherent environment.
nonisolated struct PlaybackEnvironment: Sendable {
    let remote: any RemotePlaybackClient
    let local: any LocalPlaybackEngine
    let webQueue: any WebQueueClient
    let account: any AccountSession
    let audioOutput: any AudioOutputPreparing
    let preferences: any PlaybackPreferences
    let lifecycle: any SystemLifecycleEvents
    let clock: any PlaybackClock
    let catalog: any CatalogProviding
    let playlistMutations: any PlaylistMutating
    let trackAttributes: any TrackAttributesProviding
    let queueServiceHook: (any QueueServiceHook)?

    /// Hand-written so checks can pass a hook. A defaulted stored property is
    /// dropped from the synthesized memberwise initializer, which then rejects
    /// `queueServiceHook:` as an extra argument.
    init(
        remote: any RemotePlaybackClient,
        local: any LocalPlaybackEngine,
        webQueue: any WebQueueClient,
        account: any AccountSession,
        audioOutput: any AudioOutputPreparing,
        preferences: any PlaybackPreferences,
        lifecycle: any SystemLifecycleEvents,
        clock: any PlaybackClock,
        catalog: any CatalogProviding,
        playlistMutations: any PlaylistMutating,
        trackAttributes: any TrackAttributesProviding,
        queueServiceHook: (any QueueServiceHook)? = nil
    ) {
        self.remote = remote
        self.local = local
        self.webQueue = webQueue
        self.account = account
        self.audioOutput = audioOutput
        self.preferences = preferences
        self.lifecycle = lifecycle
        self.clock = clock
        self.catalog = catalog
        self.playlistMutations = playlistMutations
        self.trackAttributes = trackAttributes
        self.queueServiceHook = queueServiceHook
    }

    static let live: PlaybackEnvironment = {
        let partnerAPI = PartnerAPI()
        return PlaybackEnvironment(
            remote: SpotifyConnectAPI(),
            local: RustPlaybackEngine.shared,
            webQueue: SpotifyWebPlayerAPI(),
            account: LiveAccountSession(),
            audioOutput: LiveAudioOutput(),
            preferences: UserDefaultsPlaybackPreferences.shared,
            lifecycle: MacSystemLifecycleEvents.shared,
            clock: SystemPlaybackClock(),
            catalog: partnerAPI,
            playlistMutations: partnerAPI,
            trackAttributes: TrackAttributesAPI()
        )
    }()
}

/// Serial owner for local blocking commands and remote network commands. The UI store receives
/// only command outcomes; it never instantiates an API client or performs C work on MainActor.
actor PlaybackCoordinator {
    private let local: any LocalPlaybackEngine
    private let remote: any RemotePlaybackClient
    private let metadataService: TrackMetadataService

    init(
        local: any LocalPlaybackEngine,
        remote: any RemotePlaybackClient,
        metadataService: TrackMetadataService? = nil
    ) {
        self.local = local
        self.remote = remote
        self.metadataService = metadataService ?? TrackMetadataService(remote: remote)
    }

    func performLocal(_ operation: LocalPlaybackOperation) async -> PlaybackEngineResult {
        local.execute(operation)
    }

    /// Maps a local engine integer into a typed command outcome. Throws only if this task
    /// was cancelled; operational failures are `Result` values.
    func performLocalCommand(
        _ operation: LocalPlaybackOperation
    ) async throws(CancellationError) -> Result<Void, PlaybackCommandFailure> {
        if Task.isCancelled { throw CancellationError() }
        let outcome = PlaybackCommandFailure.from(engineResult: local.execute(operation))
        if Task.isCancelled { throw CancellationError() }
        return outcome
    }

    func authorizeStreaming(with token: String) async -> Int32 {
        local.authorizeStreaming(with: token)
    }

    func initializeEngine() async -> PlaybackEngineResult {
        local.initialize()
    }

    func shutdownEngine() async -> PlaybackEngineResult {
        local.shutdown()
    }

    func cleanupEngine() { local.cleanup() }
    func clearStreamingCredentials() { local.clearStreamingCredentials() }
    func configureHighQualityPlayback() { local.configureHighQualityPlayback() }
    func positionMilliseconds() -> UInt32 { local.positionMilliseconds() }
    func resumePositionMilliseconds() -> UInt32 { local.resumePositionMilliseconds() }
    func queueSnapshot() -> RustQueueState? { local.queueSnapshot() }
    func disconnect() async -> PlaybackEngineResult {
        local.disconnect()
    }
    func forceReconnect() async -> Int32 {
        local.forceReconnect()
    }

    func performRemote(
        _ command: SpotifyConnectCommand,
        from sourceID: String,
        to targetID: String
    ) async throws {
        try await remote.send(command, from: sourceID, to: targetID)
    }

    func metadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        try await metadataService.metadata(for: uri)
    }

    /// Maps an arbitrary remote `Error` into a typed command outcome. `CancellationError`
    /// (including cancellation surfaced as another error while `Task.isCancelled`) is rethrown
    /// and is never an operational failure.
    func performRemoteCommand(
        _ operation: @escaping @Sendable (any RemotePlaybackClient) async throws -> Void
    ) async throws(CancellationError) -> Result<Void, PlaybackCommandFailure> {
        if Task.isCancelled { throw CancellationError() }
        do {
            try await operation(remote)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            return .failure(.remoteRejected)
        }
        if Task.isCancelled { throw CancellationError() }
        return .success(())
    }
}
