import AppKit
import AuralDomain
import Foundation
import Observation
import OSLog

nonisolated struct RustPlaybackState: Decodable, Sendable {
    var revision: UInt64?
    var sessionGeneration: UInt64?
    let isPlaying: Bool
    var isPaused: Bool?
    let trackURI: String
    let positionMS: Int64
    let durationMS: Int64
    var timestampMS: Int64?
    /// Absent in payloads from backend versions that predate repeat/shuffle reporting.
    var shuffle: Bool?
    var repeatTrack: Bool?
    var repeatContext: Bool?

    enum CodingKeys: String, CodingKey {
        case revision
        case sessionGeneration = "session_generation"
        case isPlaying = "is_playing"
        case isPaused = "is_paused"
        case trackURI = "track_uri"
        case positionMS = "position_ms"
        case durationMS = "duration_ms"
        case timestampMS = "timestamp_ms"
        case shuffle
        case repeatTrack = "repeat_track"
        case repeatContext = "repeat_context"
    }
}

nonisolated struct RustQueueState: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let uri: String
        let name: String
        let artist: String
        let imageURL: String
        let durationMS: UInt32

        enum CodingKeys: String, CodingKey {
            case uri, name, artist
            case imageURL = "image_url"
            case durationMS = "duration_ms"
        }
    }

    struct QueueItem: Decodable, Sendable {
        let uri: String
        let provider: String
    }

    let track: Item?
    let nextTracks: [QueueItem]?
    var revision: UInt64?
    var sessionGeneration: UInt64?

    enum CodingKeys: String, CodingKey {
        case track
        case nextTracks = "next_tracks"
        case revision
        case sessionGeneration = "session_generation"
    }
}

nonisolated struct RustConnectionState: Decodable, Sendable {
    var revision: UInt64?
    var sessionGeneration: UInt64?
    let sessionConnected: Bool
    let spircReady: Bool
    let isActiveDevice: Bool
    let lastError: String?
    var deviceID: String?
    var deviceName: String?

    enum CodingKeys: String, CodingKey {
        case revision
        case sessionGeneration = "session_generation"
        case sessionConnected = "session_connected"
        case spircReady = "spirc_ready"
        case isActiveDevice = "is_active_device"
        case lastError = "last_error"
        case deviceID = "device_id"
        case deviceName = "device_name"
    }
}

nonisolated struct RustDevicesState: Decodable, Sendable {
    let revision: UInt64
    let sessionGeneration: UInt64
    let devices: [ConnectDevice]

    enum CodingKeys: String, CodingKey {
        case revision
        case sessionGeneration = "session_generation"
        case devices
    }
}

nonisolated let auralAudioRendererResult: Result<AudioRenderer, AudioRendererError> = {
    do {
        return .success(try AudioRenderer())
    } catch {
        AuralLog.audio.error("Audio renderer initialization failed")
        return .failure(error as? AudioRendererError ?? .formatDescription(-1))
    }
}()

@MainActor
@Observable
final class PlaybackStore {
    typealias Phase = PlaybackSessionPhase

    private(set) var state = PlaybackState(accountEpoch: 1)

    var phase: Phase { state.session }
    var trackURI: String { state.currentTrack?.uri ?? "" }
    var trackTitle: String { state.currentTrack?.title ?? "Nothing playing" }
    var artistName: String { state.currentTrack?.artist ?? "Choose something to play" }
    var artworkURL: URL? { state.currentTrack?.artworkURL }
    var isPlaying: Bool { state.transport == .playing }
    var isShuffleEnabled: Bool { state.options.shuffle }
    var repeatMode: RepeatMode { state.options.repeatMode }
    var isActiveDevice: Bool {
        if case .local = state.owner { return true }
        return false
    }
    var position: TimeInterval { state.timing.position }
    var duration: TimeInterval { state.timing.duration }
    var positionAnchorDate: Date { state.timing.anchoredAt }
    /// Catalog state lives in its own observable store; views that only draw
    /// catalog data can depend on it without observing playback at all.
    let catalog: CatalogStore
    let history = PlaybackHistoryStore()
    @ObservationIgnored let environment: PlaybackEnvironment
    @ObservationIgnored let metadataService: TrackMetadataService
    @ObservationIgnored let coordinator: PlaybackCoordinator
    @ObservationIgnored let queueService: QueueService
    @ObservationIgnored let accountStore: AccountStore
    @ObservationIgnored let catalogSession: CatalogSessionAvailability
    @ObservationIgnored var accountEpoch: UInt64 = 1
    var queueNextEntries: [QueueEntry] {
        state.queue.entries.map {
            QueueEntry(uri: $0.uri, provider: $0.provider, occurrence: queueOccurrence($0.id))
        }
    }
    var connectDevices: [ConnectDevice] {
        state.devices.devices.map {
            ConnectDevice(id: $0.id, name: $0.name, type: $0.type, isActive: $0.isActive)
        }
    }
    var thisDeviceName = "This Mac"
    var localDeviceID: String? { state.devices.localDeviceID }
    @ObservationIgnored var lastRemoteDeviceID: String?
    var isPlaybackCommandPending: Bool {
        state.pendingCommands.keys.contains { $0 != .queue }
    }
    var hasCurrentTrackMetadata: Bool { (state.currentTrack?.metadataSource ?? .none) != .none }
    /// The first Connect snapshot describes state that predates this process. It seeds the UI,
    /// but must not be counted as something the listener just played in this Aural session.
    @ObservationIgnored var hasReceivedPlaybackSnapshot = false
    @ObservationIgnored let effects = PlaybackEffectRegistry()
    /// Nil until tried, true after a successful documented queue request, false after the
    /// desktop grant is rejected by api.spotify.com for this session.
    /// True between `endSession` starting and the next `initializePlayer`. Backend events
    /// are delivered as detached tasks, so one queued just before a logout can land after
    /// the presentation was cleared; without this gate it would mark a signed-out
    /// account's playback state `.ready` again.
    @ObservationIgnored var isTearingDown = false
    @ObservationIgnored var teardown = SessionTeardownCoalescer()
    @ObservationIgnored var teardownTask: Task<Void, Never>?
    @ObservationIgnored var terminationGate = PlaybackTerminationGate()
    @ObservationIgnored var lastEngineEventSequence: UInt64 = 0
    @ObservationIgnored var engineGeneration: UInt64 = 0
    /// MainActor watermark for Connect *callback* identity. Distinct from
    /// `state.sourceRevisions[.engineQueue]`, which tracks provenance snapshots after merge.
    @ObservationIgnored var connectQueueCallback = ConnectQueueCallbackWatermark()
    @ObservationIgnored var shuffleHistoryCache: [String: TimeInterval] = [:]
    var transientCommandError: String? { state.notice?.message }

    var isConnected: Bool { phase == .ready }
    var catalogCurrentTrack: CatalogTrack? {
        guard !trackURI.isEmpty else { return nil }
        return catalog.metadata.knownTrack(for: trackURI)
    }
    var displayedTrackTitle: String { catalogCurrentTrack?.title ?? trackTitle }
    var displayedArtistName: String { catalogCurrentTrack?.artist ?? artistName }
    var displayedArtworkURL: URL? { catalogCurrentTrack?.artworkURL ?? artworkURL }
    var hasCurrentTrack: Bool {
        !trackURI.isEmpty && (hasCurrentTrackMetadata || catalogCurrentTrack != nil)
    }
    /// Connect is account-wide: another device playing is still live playback Aural can control.
    var showsPauseControl: Bool { hasCurrentTrack && isPlaying }
    var canStartPlayback: Bool {
        isConnected && !isTearingDown && terminationGate.allowsCommands && !isPlaybackCommandPending
    }
    var canTogglePlayback: Bool { canStartPlayback && hasCurrentTrack }
    var canSkipTrack: Bool { canStartPlayback && hasCurrentTrack }

    func displayedPosition(at date: Date) -> TimeInterval {
        interpolatedPlaybackPosition(
            anchor: position,
            anchoredAt: positionAnchorDate,
            now: date,
            isPlaying: showsPauseControl,
            duration: duration
        )
    }

    var statusText: String {
        switch phase {
        case .signedOut: "Connect Spotify Premium"
        case .authorizing: "Waiting for Spotify…"
        case .connecting: "Starting Aural Connect…"
        case .recovering: "Restoring Spotify Connect…"
        case .ready:
            if let transientCommandError { transientCommandError }
            else if let remote = activeRemoteDevice {
                isPlaying ? "Playing on \(remote.name)" : "Paused on \(remote.name)"
            } else if showsPauseControl { "Playing on this Mac" }
            else { "Aural Connect is ready" }
        case let .failed(message): message
        }
    }

    init(environment: PlaybackEnvironment = .live) {
        self.environment = environment
        let metadataService = TrackMetadataService(remote: environment.remote)
        self.metadataService = metadataService
        let coordinator = PlaybackCoordinator(
            local: environment.local,
            remote: environment.remote,
            metadataService: metadataService
        )
        self.coordinator = coordinator
        queueService = QueueService(
            webQueue: environment.webQueue,
            metadata: metadataService,
            clock: environment.clock
        )
        accountStore = AccountStore(environment: environment, coordinator: coordinator)
        let catalogSession = CatalogSessionAvailability(accountEpoch: accountEpoch, isAvailable: false)
        self.catalogSession = catalogSession
        catalog = CatalogStore(
            provider: environment.catalog,
            attributesProvider: environment.trackAttributes,
            session: catalogSession
        )
        effects.replace(.engineEvents, with: Task { [weak self] in
            for await envelope in environment.local.events() {
                guard !Task.isCancelled, let self else { return }
                self.receive(envelope)
            }
        })
        effects.replace(.grantRevocations, with: Task { [weak self] in
            for await _ in environment.account.revocations() {
                guard !Task.isCancelled else { return }
                await self?.handleGrantRevocation()
            }
        })
        effects.replace(.lifecycle, with: Task { [weak self] in
            for await event in environment.lifecycle.events() {
                guard !Task.isCancelled, let self else { return }
                await self.receive(event)
            }
        })
        effects.replace(.preferencesRestore, with: Task { [weak self] in
            guard let self else { return }
            let epoch = self.accountEpoch
            await self.queueService.reset(accountEpoch: self.accountEpoch)
            guard !Task.isCancelled, self.accountEpoch == epoch else { return }
            self.setShuffleEnabled(await environment.preferences.shuffleEnabled())
            guard !Task.isCancelled, self.accountEpoch == epoch else { return }
            self.lastRemoteDeviceID = await environment.preferences.lastRemoteDeviceID()
            self.shuffleHistoryCache = await environment.preferences.shuffleHistory()
        })
        accountStore.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.catalogSession.update(
                accountEpoch: self.accountEpoch,
                isAvailable: phase == .ready
            )
            self.send(.session(phase), source: .account)
        }
        accountStore.onReady = { [weak self] in
            guard let self else { return }
            let epoch = self.accountEpoch
            self.effects.replace(.catalogLoad, with: Task { [weak self] in
                guard let self, self.accountEpoch == epoch else { return }
                await self.catalog.homeLibrary.load()
            })
        }
    }

    /// macOS suspends the process on sleep and sockets die underneath it; without this the
    /// first play after waking would fail until the user manually reconnected.
    ///
    /// The backend's `forceReconnect` captures the playing track and position before tearing
    /// down and restores them through its own reconnection loop, so playback resumes where it
    /// was. The backend also self-reports disconnections; this covers the case where it does
    /// not notice — a clean sleep can look, to it, like nothing happened at all.
    private func receive(_ event: SystemLifecycleEvent) async {
        guard isConnected else { return }
        switch event {
        case .willSleep:
            _ = await coordinator.disconnect()
        case .didWake:
            statusTextFallbackAfterWake()
            _ = await coordinator.forceReconnect()
        }
    }

    /// Tells the listener what is happening instead of leaving the stale "Playing" label up
    /// while the backend rebuilds its session.
    private func statusTextFallbackAfterWake() {
        guard showsPauseControl else { return }
        showTransientCommandError("Restoring playback after sleep…")
    }

    var activeRemoteDevice: ConnectDevice? {
        guard !isActiveDevice, hasCurrentTrack else { return nil }
        let device: PlaybackDevice?
        switch state.owner {
        case let .remote(value), let .uncertain(.some(value)):
            device = value
        default:
            device = nil
        }
        if let device {
            return ConnectDevice(
                id: device.id,
                name: device.name,
                type: device.type,
                isActive: device.isActive
            )
        }
        return nil
    }

    var commandRoute: ConnectCommandRoute {
        connectCommandRoute(owner: state.owner, localDeviceID: localDeviceID)
    }

    /// The only mutation entrance for the atomic playback snapshot.
    /// Engine callbacks pass their payload `sessionGeneration` as `engineEpoch`. Other events
    /// omit it and use `engineGeneration`, which mirrors `state.engineEpoch` after `reduce`.
    @discardableResult
    func send(
        _ event: PlaybackEvent,
        source: PlaybackEventSource,
        revision: UInt64? = nil,
        engineEpoch: UInt64? = nil,
        receivedAt: Date = Date()
    ) -> Bool {
        let stampedEngineEpoch = engineEpoch ?? engineGeneration
        var next = state
        let accepted = PlaybackReducer.reduce(
            &next,
            envelope: PlaybackEventEnvelope(
                accountEpoch: accountEpoch,
                engineEpoch: stampedEngineEpoch,
                source: source,
                revision: revision,
                receivedAt: receivedAt,
                event: event
            )
        )
        if accepted {
            state = next
            engineGeneration = next.engineEpoch
            return true
        }
        AuralLog.playback.debug(
            "Rejected event; source=\(String(describing: source), privacy: .public); account=\(self.accountEpoch, privacy: .public); engine=\(stampedEngineEpoch, privacy: .public); revision=\(String(describing: revision), privacy: .public)"
        )
        return false
    }

    func setPresentation(
        track: CurrentTrack?,
        transport: PlaybackTransportState? = nil,
        timing: PlaybackTiming? = nil,
        source: PlaybackEventSource = .user
    ) {
        send(
            .presentation(PlaybackPresentationSnapshot(
                currentTrack: track,
                transport: transport ?? state.transport,
                timing: timing ?? state.timing
            )),
            source: source
        )
    }

    func setTrackMetadata(
        uri: String,
        title: String?,
        artist: String?,
        artworkURL: URL?,
        duration: TimeInterval,
        provenance: MetadataProvenance
    ) {
        send(
            .trackMetadata(PlaybackTrackMetadata(
                uri: uri,
                title: title,
                artist: artist,
                artworkURL: artworkURL,
                duration: duration,
                source: provenance
            )),
            source: .metadata
        )
    }

    func setTransport(_ transport: PlaybackTransportState, anchoredAt: Date? = nil) {
        if let anchoredAt {
            setPresentation(
                track: state.currentTrack,
                transport: transport,
                timing: PlaybackTiming(
                    position: position,
                    duration: duration,
                    anchoredAt: anchoredAt
                )
            )
        } else {
            send(.transport(transport), source: .user)
        }
    }

    func setTiming(position: TimeInterval, duration: TimeInterval? = nil, anchoredAt: Date = Date()) {
        send(
            .timing(position: position, duration: duration ?? self.duration, anchoredAt: anchoredAt),
            source: .user
        )
    }

    func setShuffleEnabled(_ enabled: Bool) {
        var options = state.options
        options.shuffle = enabled
        send(.options(options), source: .user)
    }

    func setRepeatMode(_ mode: RepeatMode) {
        var options = state.options
        options.repeatMode = mode
        send(.options(options), source: .user)
    }

    func setNotice(_ message: String?) {
        send(.notice(message.map { PlaybackNotice(message: $0) }), source: .user)
    }

    private func queueOccurrence(_ id: String) -> Int {
        id.split(separator: "-", maxSplits: 1).first.flatMap { Int($0) } ?? 0
    }
}

nonisolated enum LiveSpotifyError: LocalizedError {
    case streamingAuthorization(Int32)

    var errorDescription: String? {
        switch self {
        case let .streamingAuthorization(code):
            "Spotify playback authorization failed (\(code))"
        }
    }
}
