import Foundation

/// One typed command Rust's `ShimPlayer` forwards to Swift for the Stage 1 audio path
/// (#208). Every field is present regardless of `kind`; unused fields carry zero/empty
/// values on the C side, matching the shared `AuralAudioCommand` ABI shape.
public struct AudioCommand: Sendable, Equatable {
    /// Rejects commands from a session that has since been torn down and rebuilt.
    /// Older than the session's own generation makes the whole command stale.
    public let sessionGeneration: UInt64
    /// Spirc's identity for one load attempt; stamped back onto every report for that load.
    public let playRequestID: UInt64
    public let kind: Kind
    public let trackURI: String
    /// Spotify GID, exactly 16 bytes.
    public let trackGID: [UInt8]
    /// Content file id, exactly 20 bytes. Identity used to match a `load` against a
    /// previously requested `preload`.
    public let fileID: [UInt8]
    /// Raw librespot `AudioFileFormat`.
    public let audioFormat: UInt8
    public let positionMs: UInt32
    public let startPlaying: Bool
    /// Known duration in milliseconds, when the caller already has it. Zero means unknown;
    /// the session then waits for a `.durationKnown` pipeline event.
    public let durationMs: UInt32

    public init(
        sessionGeneration: UInt64,
        playRequestID: UInt64,
        kind: Kind,
        trackURI: String,
        trackGID: [UInt8],
        fileID: [UInt8],
        audioFormat: UInt8,
        positionMs: UInt32,
        startPlaying: Bool,
        durationMs: UInt32
    ) {
        self.sessionGeneration = sessionGeneration
        self.playRequestID = playRequestID
        self.kind = kind
        self.trackURI = trackURI
        self.trackGID = trackGID
        self.fileID = fileID
        self.audioFormat = audioFormat
        self.positionMs = positionMs
        self.startPlaying = startPlaying
        self.durationMs = durationMs
    }

    /// Mirrors Spirc's `Load/Play/Pause/Seek/Stop/Preload` forwarded by `ShimPlayer`.
    public enum Kind: UInt8, Sendable, Equatable {
        case load
        case play
        case pause
        case seek
        case stop
        case preload
    }
}

/// What kind of fact an `AudioReport` carries back to Rust, matching
/// `aural_playback_report_audio`'s `kind` argument.
public enum AudioReportKind: UInt8, Sendable, Equatable {
    case playing
    case paused
    case position
    case seeked
    case positionCorrection
    case endOfTrack
    case unavailable
    case stopped
    case timeToPreloadNext
    case duration
}

/// One fact reported back across the audio-command boundary. `playRequestID` and
/// `sessionGeneration` let Rust discard a report for a load it has since abandoned.
public struct AudioReport: Sendable, Equatable {
    public let sessionGeneration: UInt64
    public let playRequestID: UInt64
    public let kind: AudioReportKind
    public let positionMs: UInt32
    public let durationMs: UInt32

    public init(
        sessionGeneration: UInt64,
        playRequestID: UInt64,
        kind: AudioReportKind,
        positionMs: UInt32,
        durationMs: UInt32
    ) {
        self.sessionGeneration = sessionGeneration
        self.playRequestID = playRequestID
        self.kind = kind
        self.positionMs = positionMs
        self.durationMs = durationMs
    }
}

/// A track identity the session is loading, holding, or has cached ahead of time.
/// `durationMs` starts nil unless the caller already knew it, and is filled in once a
/// `.durationKnown` pipeline event arrives.
public struct LoadedTrack: Sendable, Equatable {
    public let playRequestID: UInt64
    public let trackURI: String
    public let fileID: [UInt8]
    public let format: UInt8
    public var durationMs: UInt32?

    public init(
        playRequestID: UInt64,
        trackURI: String,
        fileID: [UInt8],
        format: UInt8,
        durationMs: UInt32? = nil
    ) {
        self.playRequestID = playRequestID
        self.trackURI = trackURI
        self.fileID = fileID
        self.format = format
        self.durationMs = durationMs
    }
}

/// Decode-pipeline facts the audio path reports inward, distinct from the outward
/// `AudioReport` the session emits toward Rust. Position throttling (reporting at most
/// every 200 ms) is the caller's job; every `.position` that reaches `apply(pipelineEvent:)`
/// produces a report.
public enum PipelineEvent: Equatable, Sendable {
    case playing
    case paused
    case position(UInt32)
    case seeked(UInt32)
    case endOfTrack
    case failed(String)
    case stopped
    case durationKnown(UInt32)
}

/// A side effect the reducer asks its caller to perform. The reducer never performs I/O
/// itself; it only decides what should happen and hands back a description of it.
public enum Effect: Equatable, Sendable {
    /// Start the audio-key/CDN/decrypt/decode pipeline for `LoadedTrack`. `reusingPreload`
    /// is true when the file was already sitting in `preloaded`, so the caller can skip
    /// re-fetching and reuse the work already in flight or completed for it.
    case beginLoad(LoadedTrack, startPlaying: Bool, positionMs: UInt32, reusingPreload: Bool)
    /// Start decoding a track ahead of time without disturbing current playback.
    case beginPreload(LoadedTrack)
    case play
    case pause
    case seek(positionMs: UInt32)
    case stop
    case report(AudioReport)
    /// The command's `sessionGeneration` was older than the session's; nothing else happens.
    case ignoreStale(AudioCommand)
}

/// Pure reducer for the Stage 1 audio path (#208): turns Rust's forwarded Spirc commands
/// and the decode pipeline's own events into effects, with no I/O of its own.
///
/// `AudioPlaybackSession` is the Swift-owned in-between of ADR-004: Rust still owns Spirc
/// and the protocol row, but what a `Load`/`Play`/`Pause`/`Seek`/`Stop`/`Preload` command
/// actually *does* — including staleness, preload reuse, and the preload-ahead threshold —
/// is decided here, not in the C leaf.
public struct AudioPlaybackSession: Sendable, Equatable {
    /// Where the currently loaded track stands. `loading` covers the window between
    /// `beginLoad` and the first `.playing`/`.paused` pipeline event; `ready` is loaded and
    /// paused; `stopped` is a deliberate stop (as opposed to `idle`, which is "never loaded
    /// anything for this generation").
    public enum Phase: Sendable, Equatable {
        case idle
        case loading(playRequestID: UInt64)
        case ready(playRequestID: UInt64, paused: Bool)
        case playing(playRequestID: UInt64)
        case stopped
    }

    public private(set) var phase: Phase
    public private(set) var current: LoadedTrack?
    public private(set) var positionMs: UInt32
    public private(set) var sessionGeneration: UInt64
    public private(set) var preloaded: LoadedTrack?
    /// Whether `.timeToPreloadNext` has already been reported for the current load. Cleared
    /// on every new `load` and on `endOfTrack`/`stop` so the next load gets its own report.
    public private(set) var timeToPreloadReported: Bool

    public init(sessionGeneration: UInt64 = 0) {
        self.phase = .idle
        self.current = nil
        self.positionMs = 0
        self.sessionGeneration = sessionGeneration
        self.preloaded = nil
        self.timeToPreloadReported = false
    }

    /// How close to the end of a track `.timeToPreloadNext` fires, mirroring the Rust
    /// leaf's existing "under 30 s remaining" threshold.
    private static let preloadWindowMs: UInt32 = 30_000

    // MARK: - Commands

    /// Applies one forwarded Spirc command, returning the effects the caller must perform.
    ///
    /// A command older than `sessionGeneration` is stale and produces `[.ignoreStale]`
    /// with no other change: the session that issued it no longer exists. A command newer
    /// than `sessionGeneration` means a session rebuild happened without this reducer
    /// hearing about it directly; the session adopts the new generation and drops
    /// `current`/`preloaded` before applying the command, since neither can be trusted to
    /// still describe anything the new session cares about.
    public mutating func apply(_ command: AudioCommand) -> [Effect] {
        if command.sessionGeneration < sessionGeneration {
            return [.ignoreStale(command)]
        }
        if command.sessionGeneration > sessionGeneration {
            sessionGeneration = command.sessionGeneration
            phase = .idle
            current = nil
            preloaded = nil
            positionMs = 0
            timeToPreloadReported = false
        }
        switch command.kind {
        case .load:
            return applyLoad(command)
        case .preload:
            return applyPreload(command)
        case .play:
            return applyPlay()
        case .pause:
            return applyPause()
        case .seek:
            return applySeek(command)
        case .stop:
            return applyStop()
        }
    }

    /// A `load` replaces whatever is current. If a track was actively `.playing`, a `.stop`
    /// effect is emitted first so the caller tears down the old pipeline before starting the
    /// new one. When the requested file id matches `preloaded`, the caller can reuse that
    /// work instead of fetching from scratch — the `beginLoad` effect still fires (a fresh
    /// `playRequestID` needs its own load bookkeeping) but carries `reusingPreload: true`,
    /// and the consumed `preloaded` slot is cleared.
    private mutating func applyLoad(_ command: AudioCommand) -> [Effect] {
        var effects: [Effect] = []
        if case .playing = phase {
            effects.append(.stop)
        }

        let reusingPreload = preloaded != nil && preloaded?.fileID == command.fileID
        if reusingPreload {
            preloaded = nil
        }

        let track = LoadedTrack(
            playRequestID: command.playRequestID,
            trackURI: command.trackURI,
            fileID: command.fileID,
            format: command.audioFormat,
            durationMs: command.durationMs > 0 ? command.durationMs : nil
        )
        current = track
        positionMs = command.positionMs
        timeToPreloadReported = false
        phase = .loading(playRequestID: command.playRequestID)

        effects.append(
            .beginLoad(
                track,
                startPlaying: command.startPlaying,
                positionMs: command.positionMs,
                reusingPreload: reusingPreload
            )
        )
        return effects
    }

    /// A `preload` decodes a track ahead of time without touching `phase` or `current`:
    /// whatever is playing keeps playing. The result replaces any previous `preloaded`.
    private mutating func applyPreload(_ command: AudioCommand) -> [Effect] {
        let track = LoadedTrack(
            playRequestID: command.playRequestID,
            trackURI: command.trackURI,
            fileID: command.fileID,
            format: command.audioFormat,
            durationMs: command.durationMs > 0 ? command.durationMs : nil
        )
        preloaded = track
        return [.beginPreload(track)]
    }

    /// `play` only does something once a load has reported itself paused-and-ready; from
    /// `idle`, `loading`, `stopped`, or while already `playing` it is a no-op, since there is
    /// either nothing to start or nothing left to do.
    private mutating func applyPlay() -> [Effect] {
        guard case .ready(let requestID, paused: true) = phase else { return [] }
        phase = .playing(playRequestID: requestID)
        return [.play]
    }

    /// `pause` only does something while actively `playing`; otherwise a no-op.
    private mutating func applyPause() -> [Effect] {
        guard case .playing(let requestID) = phase else { return [] }
        phase = .ready(playRequestID: requestID, paused: true)
        return [.pause]
    }

    /// `seek` only does something once a track is loaded (`ready` or `playing`); from
    /// `idle`, `loading`, or `stopped` it is a no-op. The target position is clamped to the
    /// known duration so a stale or out-of-range seek cannot ask the decoder to seek past
    /// the end of the file.
    private mutating func applySeek(_ command: AudioCommand) -> [Effect] {
        switch phase {
        case .ready, .playing:
            let clamped = clamp(command.positionMs)
            positionMs = clamped
            return [.seek(positionMs: clamped)]
        default:
            return []
        }
    }

    /// `stop` from `idle` or an already-`stopped` session is a no-op; there is nothing
    /// running to stop. Otherwise it drops `current` and moves to `stopped`, distinct from
    /// `idle` so callers can tell "deliberately stopped" from "never loaded".
    private mutating func applyStop() -> [Effect] {
        switch phase {
        case .idle, .stopped:
            return []
        default:
            phase = .stopped
            current = nil
            timeToPreloadReported = false
            return [.stop]
        }
    }

    private func clamp(_ target: UInt32) -> UInt32 {
        guard let duration = current?.durationMs else { return target }
        return min(target, duration)
    }

    // MARK: - Pipeline events

    /// Applies one fact from the decode pipeline, returning the reports the caller must
    /// send back to Rust. `.playing`/`.paused` move `phase` to match what the pipeline says
    /// is actually happening; both are no-ops if nothing is currently loaded (a pipeline
    /// event arriving after the load it belongs to was superseded).
    ///
    /// `.failed` reports `.unavailable` and moves to `stopped`: an unplayable file is not
    /// recoverable by retrying the same load. `.endOfTrack` reports `.endOfTrack` and moves
    /// to `idle`, clearing `current` and the position, since the caller (Spirc, via Rust)
    /// owns advancing to whatever comes next.
    public mutating func apply(pipelineEvent event: PipelineEvent) -> [Effect] {
        switch event {
        case .playing:
            guard let current else { return [] }
            phase = .playing(playRequestID: current.playRequestID)
            return [report(.playing)]

        case .paused:
            guard let current else { return [] }
            phase = .ready(playRequestID: current.playRequestID, paused: true)
            return [report(.paused)]

        case .position(let ms):
            positionMs = ms
            var effects = [report(.position, positionMsOverride: ms)]
            if let preloadReport = timeToPreloadNextIfDue(at: ms) {
                effects.append(preloadReport)
            }
            return effects

        case .seeked(let ms):
            positionMs = ms
            return [report(.seeked, positionMsOverride: ms)]

        case .endOfTrack:
            let effect = report(.endOfTrack, positionMsOverride: current?.durationMs ?? positionMs)
            phase = .idle
            current = nil
            positionMs = 0
            timeToPreloadReported = false
            return [effect]

        case .failed:
            let effect = report(.unavailable)
            phase = .stopped
            current = nil
            return [effect]

        case .stopped:
            let effect = report(.stopped)
            phase = .stopped
            current = nil
            return [effect]

        case .durationKnown(let ms):
            current?.durationMs = ms
            return [report(.duration, durationMsOverride: ms)]
        }
    }

    /// Emits `.timeToPreloadNext` exactly once per load, the first time a `.position`
    /// arrives with 30 s or less of known duration remaining. Duration must already be
    /// known; a track whose duration was never reported never fires this.
    private mutating func timeToPreloadNextIfDue(at ms: UInt32) -> Effect? {
        guard !timeToPreloadReported, let duration = current?.durationMs else { return nil }
        let remaining = duration > ms ? duration - ms : 0
        guard remaining <= Self.preloadWindowMs else { return nil }
        timeToPreloadReported = true
        return report(.timeToPreloadNext, positionMsOverride: ms)
    }

    /// Stamps a report with the session's current generation and, where one is loaded, its
    /// `playRequestID`/duration — so a report from a superseded load can be told apart from
    /// the one that is actually current.
    private func report(
        _ kind: AudioReportKind,
        positionMsOverride: UInt32? = nil,
        durationMsOverride: UInt32? = nil
    ) -> Effect {
        .report(
            AudioReport(
                sessionGeneration: sessionGeneration,
                playRequestID: current?.playRequestID ?? 0,
                kind: kind,
                positionMs: positionMsOverride ?? positionMs,
                durationMs: durationMsOverride ?? current?.durationMs ?? 0
            )
        )
    }
}
