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
        var uid: String?

        enum CodingKeys: String, CodingKey {
            case uri, provider, uid
        }
    }

    struct ProtocolTrack: Decodable, Sendable {
        let uri: String
        let uid: String
        let provider: String
        var metadata: [String: String]?
        var removed: [String]?
        var blocked: [String]?
        var restrictions: [String: [String]]?
        var albumURI: String?
        var disallowReasons: [String]?
        var artistURI: String?

        enum CodingKeys: String, CodingKey {
            case uri, uid, provider, metadata, removed, blocked, restrictions
            case albumURI = "album_uri"
            case disallowReasons = "disallow_reasons"
            case artistURI = "artist_uri"
        }

        func domainTrack() -> QueueProtocolTrack {
            QueueProtocolTrack(
                uri: uri,
                uid: uid,
                provider: provider,
                metadata: metadata ?? [:],
                removed: removed ?? [],
                blocked: blocked ?? [],
                restrictions: restrictions ?? [:],
                albumURI: albumURI ?? "",
                disallowReasons: disallowReasons ?? [],
                artistURI: artistURI ?? ""
            )
        }
    }

    let track: Item?
    let nextTracks: [QueueItem]?
    let prevTracks: [QueueItem]?
    var protocolNextTracks: [ProtocolTrack]?
    var protocolPrevTracks: [ProtocolTrack]?
    var queueRevision: String?
    var disallowSetQueue: Bool?
    var disallowRemovingFromNextTracks: Bool?
    var revision: UInt64?
    var sessionGeneration: UInt64?

    enum CodingKeys: String, CodingKey {
        case track
        case nextTracks = "next_tracks"
        case prevTracks = "prev_tracks"
        case protocolNextTracks = "protocol_next_tracks"
        case protocolPrevTracks = "protocol_prev_tracks"
        case queueRevision = "queue_revision"
        case disallowSetQueue = "disallow_set_queue"
        case disallowRemovingFromNextTracks = "disallow_removing_from_next_tracks"
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

    /// Catalog state lives in its own observable store; views that only draw
    /// catalog data can depend on it without observing playback at all.
    let catalog: CatalogStore
    let history = PlaybackHistoryStore()
    @ObservationIgnored let environment: PlaybackEnvironment
    /// App-composed mutation-feedback owner. Queue and playlist mutations
    /// report through this presenter rather than `PlaybackState.notice`.
    @ObservationIgnored let feedback: TransientFeedbackPresenter
    @ObservationIgnored let metadataService: TrackMetadataService
    @ObservationIgnored let coordinator: PlaybackCoordinator
    @ObservationIgnored let queueService: QueueService
    @ObservationIgnored let accountStore: AccountStore
    @ObservationIgnored let catalogSession: CatalogSessionAvailability
    /// Read-only projection of `AccountStore.epoch`. Do not increment or assign this value.
    var accountEpoch: UInt64 { accountStore.epoch }
    var thisDeviceName = "This Mac"
    @ObservationIgnored var lastRemoteDeviceID: String?
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
    /// Connect protocol queue used for `set_queue`. This is a MainActor projection of
    /// `QueueService`'s mutation snapshot, updated only after accepted Connect intake or a
    /// committed replacement. Web inspector refresh must not write it.
    @ObservationIgnored var queueMutation: QueueMutationSnapshot?
    /// Lifetime token for one in-flight Connect `set_queue` replacement. Not a source revision.
    /// A finished request clears only its own token so teardown cannot drop a newer session gate.
    @ObservationIgnored var queueReplacementToken: UUID?

    init(
        environment: PlaybackEnvironment = .live,
        feedback: TransientFeedbackPresenter,
        queueServiceHook: any QueueServiceHook = InertQueueServiceHook()
    ) {
        self.environment = environment
        self.feedback = feedback
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
            clock: environment.clock,
            hook: queueServiceHook
        )
        accountStore = AccountStore(environment: environment, coordinator: coordinator)
        let catalogSession = CatalogSessionAvailability(accountEpoch: accountStore.epoch, isAvailable: false)
        self.catalogSession = catalogSession
        catalog = CatalogStore(
            provider: environment.catalog,
            attributesProvider: environment.trackAttributes,
            playlistMutations: environment.playlistMutations,
            session: catalogSession,
            feedback: feedback
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

    /// The only mutation entrance for the atomic playback snapshot.
    /// Engine callbacks pass their payload `sessionGeneration` as `engineEpoch`. Asynchronous
    /// outcomes pass the account and engine identity captured when the work started so
    /// `PlaybackReducer` rejects stale results. Unstamped events use `accountEpoch` (the
    /// `AccountStore.epoch` projection) and `engineGeneration`, which mirrors `state.engineEpoch`
    /// after `reduce`. Reducer-owned `state.accountEpoch` is accepted snapshot state, not a
    /// second imperative lifecycle owner. Omitted `receivedAt` is the orchestration clock;
    /// engine intake passes the fan-out receipt time, which stays distinct from source revisions.
    @discardableResult
    func send(
        _ event: PlaybackEvent,
        source: PlaybackEventSource,
        revision: UInt64? = nil,
        engineEpoch: UInt64? = nil,
        accountEpoch: UInt64? = nil,
        receivedAt: Date? = nil
    ) -> Bool {
        let stampedAccountEpoch = accountEpoch ?? self.accountEpoch
        let stampedEngineEpoch = engineEpoch ?? engineGeneration
        var next = state
        let accepted = PlaybackReducer.reduce(
            &next,
            envelope: PlaybackEventEnvelope(
                accountEpoch: stampedAccountEpoch,
                engineEpoch: stampedEngineEpoch,
                source: source,
                revision: revision,
                receivedAt: receivedAt ?? environment.clock.now(),
                event: event
            )
        )
        if accepted {
            state = next
            engineGeneration = next.engineEpoch
            return true
        }
        AuralLog.playback.debug(
            "Rejected event; source=\(String(describing: source), privacy: .public); account=\(stampedAccountEpoch, privacy: .public); engine=\(stampedEngineEpoch, privacy: .public); revision=\(String(describing: revision), privacy: .public)"
        )
        return false
    }

    @discardableResult
    func setPresentation(
        track: CurrentTrack?,
        transport: PlaybackTransportState? = nil,
        timing: PlaybackTiming? = nil,
        source: PlaybackEventSource = .user,
        accountEpoch: UInt64? = nil,
        engineEpoch: UInt64? = nil
    ) -> Bool {
        send(
            .presentation(PlaybackPresentationSnapshot(
                currentTrack: track,
                transport: transport ?? state.transport,
                timing: timing ?? state.timing
            )),
            source: source,
            engineEpoch: engineEpoch,
            accountEpoch: accountEpoch
        )
    }

    @discardableResult
    func setTrackMetadata(
        uri: String,
        title: String?,
        artist: String?,
        artworkURL: URL?,
        duration: TimeInterval,
        provenance: MetadataProvenance,
        accountEpoch: UInt64? = nil,
        engineEpoch: UInt64? = nil
    ) -> Bool {
        send(
            .trackMetadata(PlaybackTrackMetadata(
                uri: uri,
                title: title,
                artist: artist,
                artworkURL: artworkURL,
                duration: duration,
                source: provenance
            )),
            source: .metadata,
            engineEpoch: engineEpoch,
            accountEpoch: accountEpoch
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

    @discardableResult
    func setTiming(
        position: TimeInterval,
        duration: TimeInterval? = nil,
        anchoredAt: Date? = nil,
        accountEpoch: UInt64? = nil,
        engineEpoch: UInt64? = nil
    ) -> Bool {
        send(
            .timing(
                position: position,
                duration: duration ?? self.duration,
                anchoredAt: anchoredAt ?? environment.clock.now()
            ),
            source: .user,
            engineEpoch: engineEpoch,
            accountEpoch: accountEpoch
        )
    }

    func setShuffleEnabled(_ enabled: Bool) {
        var options = state.options
        options.shuffle = enabled
        send(.options(options), source: .user)
    }

    func setRepeatMode(_ mode: RepeatMode) {
        setRepeat(mode: mode, flags: mode.flags)
    }

    func setRepeat(mode: RepeatMode, flags: RepeatFlags) {
        var options = state.options
        options.repeatMode = mode
        options.repeatFlags = flags
        send(.options(options), source: .user)
    }

    func setNotice(_ message: String?) {
        send(.notice(message.map { PlaybackNotice(message: $0) }), source: .user)
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
