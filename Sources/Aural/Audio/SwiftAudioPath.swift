//
//  SwiftAudioPath.swift
//  Aural
//
//  The Swift half of Stage 1 of #201 (#208): what `AudioPlaybackSession` decides, this performs.
//
//  Rust's `ShimPlayer` forwards Spirc's Load/Play/Pause/Seek/Stop/Preload here as
//  `AudioCommand`s. Each one goes through the reducer, which returns effects; this file turns
//  those effects into real work -- audio key, storage-resolve, ranged CDN fetch, AES-CTR
//  decrypt, Vorbis decode into `AudioRenderer` -- and feeds the pipeline's own events back
//  through the same reducer. Reports the reducer produces go out through
//  `aural_playback_report_audio`, where Rust turns them back into `PlayerEvent`s.
//
//  Ordering: every input, from whichever thread it arrives on, is queued on one `AsyncStream`
//  and applied by a single consumer. Spirc's commands are ordered (a `load` then a `play` means
//  something different from the reverse), and so are a pipeline's events, so applying them
//  concurrently would be wrong however carefully the reducer itself is written. Work that has to
//  await the network runs in its own `Task` so the mailbox keeps draining while it does.
//

import AuralDomain
import Foundation

/// The byte-range surface one loaded track exposes to the decode path, plus the whole-file
/// operations the audio path needs around it. Injectable so checks can drive the whole
/// reducer-to-effects machinery against an in-memory fake instead of a CDN.
protocol AudioTrackByteSource: DecodeByteSource {
    /// The file's total byte length, fetching whatever it takes to learn it.
    func totalLength() async throws -> Int
    /// Downloads every byte still missing. Gates `TimeToPreloadNext`.
    func downloadFully() async throws
    /// Keeps the download a few seconds of audio ahead of `positionMs`, so the decode loop's
    /// next read is usually already stored. Best effort: a failure here is not a playback
    /// failure, because the read that actually needs the bytes reports its own.
    func prefetchAhead(ofPositionMs positionMs: UInt32) async
}

/// Builds the byte source for one track: audio key, storage-resolve, and the ranged fetcher
/// behind them. The one seam between this file and the network.
protocol AudioTrackByteSourceProviding: Sendable {
    func makeSource(
        trackGID: [UInt8],
        fileID: [UInt8],
        format: SpotifyAudioFormat
    ) async throws -> any AudioTrackByteSource
}

/// Where decoded PCM goes, and the start/stop the renderer needs that `PCMSink` alone does not
/// express. `AudioRenderer` is the production conformer; checks use a fake.
protocol AudioOutput: PCMSink {
    /// Begins rendering and re-anchors the renderer's pacing budget.
    func start()
    /// Stops rendering and drops whatever is buffered.
    func stop()
}

extension AudioRenderer: AudioOutput {}

/// Adapts any `DecodeByteSource` to `OggSeeker`'s reader, whose `length` is non-optional and
/// synchronous. Built once per seek, after the total length is already known.
struct DecodeByteSourceSeekReader: OggByteReader {
    let source: any DecodeByteSource
    let length: Int

    func read(offset: Int, length: Int) async throws -> Data {
        try await source.read(offset: offset, length: length)
    }
}

/// Drives one process's Swift audio path.
///
/// A generation change is not a reason to rebuild it: `AudioPlaybackSession` adopts a newer
/// `sessionGeneration` from the command that carries it, tearing down whatever the previous
/// generation left running first.
actor SwiftAudioPath {
    /// One queued input. Both kinds go through the same mailbox so a pipeline event can never
    /// overtake the command that superseded the pipeline it came from.
    private enum Inbound: Sendable {
        case command(AudioCommand)
        case pipelineEvent(AudioPlaybackSession.PipelineEventDelivery)
    }

    private let sources: any AudioTrackByteSourceProviding
    private let output: any AudioOutput
    private let report: @Sendable (AudioReport) -> Void
    private let makePipeline: @Sendable () -> VorbisDecodePipeline

    private let stream: AsyncStream<Inbound>
    private nonisolated let inbox: AsyncStream<Inbound>.Continuation

    private var session = AudioPlaybackSession()
    /// The pipeline for the load `session.current` names, and the network work feeding it.
    private var pipeline: VorbisDecodePipeline?
    private var loadTask: Task<Void, Never>?
    private var source: (any AudioTrackByteSource)?
    /// The track a `beginPreload` is warming, and the task doing it, so a `load` for the same
    /// file can adopt the work instead of starting over.
    private var preload: (fileID: [UInt8], task: Task<any AudioTrackByteSource, Error>)?
    /// The `.timeToPreloadNext` report withheld until the file finishes downloading; see
    /// `sendReport`.
    private var preloadReportTask: Task<Void, Never>?

    /// Whether a `pause` has arrived that the pipeline has not been able to honor yet, because
    /// there was no pipeline when it did. `load(startPlaying:)` seeds it, and `play`/`pause`
    /// while still `.loading` change it — the #216 rule that transport commands must not be
    /// dropped during a load, expressed as the one bit the pipeline needs when it starts.
    private var startsPaused = false
    /// A `seek` that arrived before the pipeline existed, replayed once it does.
    private var pendingSeekMs: UInt32?

    /// `AudioPlaybackSession.LoadedTrack` carries no track GID (it is not part of what the
    /// reducer decides with), but the audio-key request needs one. Held for exactly as long as
    /// the command that carried it is being applied.
    private var pendingTrackGID: (playRequestID: UInt64, gid: [UInt8])?
    /// The GID for the load currently running, and for the preload being warmed.
    private var currentTrackGID: [UInt8] = []
    private var preloadTrackGID: [UInt8] = []

    init(
        sources: any AudioTrackByteSourceProviding,
        output: any AudioOutput,
        makePipeline: @escaping @Sendable () -> VorbisDecodePipeline = { VorbisDecodePipeline() },
        report: @escaping @Sendable (AudioReport) -> Void
    ) {
        self.sources = sources
        self.output = output
        self.makePipeline = makePipeline
        self.report = report
        (stream, inbox) = AsyncStream.makeStream(of: Inbound.self)
    }

    /// Queues one forwarded Spirc command. Called from the engine's Tokio runtime through the C
    /// callback, so it must not block and must not touch actor state directly.
    nonisolated func deliver(_ command: AudioCommand) {
        inbox.yield(.command(command))
    }

    /// Drains the mailbox until the stream finishes. `RustPlaybackEngine` starts this once.
    func run() async {
        for await item in stream {
            switch item {
            case let .command(command):
                pendingTrackGID = (command.playRequestID, command.trackGID)
                perform(session.apply(command))
                pendingTrackGID = nil
            case let .pipelineEvent(delivery):
                apply(delivery)
            }
        }
    }

    /// Reducer state, for checks. Production code observes this path only through its reports.
    var phase: AudioPlaybackSession.Phase { session.phase }

    // MARK: - Effects

    private func perform(_ effects: [AudioPlaybackSession.Effect]) {
        for effect in effects {
            perform(effect)
        }
    }

    private func perform(_ effect: AudioPlaybackSession.Effect) {
        switch effect {
        case let .beginLoad(track, startPlaying, positionMs, reusingPreload):
            beginLoad(track, startPlaying: startPlaying, positionMs: positionMs, reusingPreload: reusingPreload)
        case let .beginPreload(track):
            beginPreload(track)
        case .cancelPreload:
            cancelPreload()
        case .play:
            startsPaused = false
            output.start()
            pipeline?.resume()
        case .pause:
            startsPaused = true
            pipeline?.pause()
        case let .seek(positionMs):
            seek(to: positionMs)
        case .stop:
            teardown()
        case let .report(audioReport):
            sendReport(audioReport)
        case let .ignoreStale(command):
            debugLog("SwiftAudioPath", "Ignoring stale command \(command.kind)")
        case let .ignoreStalePipelineEvent(delivery):
            debugLog("SwiftAudioPath", "Ignoring stale pipeline event for load \(delivery.playRequestID)")
        }
    }

    /// Starts the fetch/decrypt/decode work for `track`.
    ///
    /// The reducer has already emitted `.stop` before this whenever a pipeline was live, so this
    /// only has to cancel the previous *load* task: the network work that may still be in flight
    /// for a load that never reached a pipeline.
    private func beginLoad(
        _ track: AudioPlaybackSession.LoadedTrack,
        startPlaying: Bool,
        positionMs: UInt32,
        reusingPreload: Bool
    ) {
        loadTask?.cancel()
        startsPaused = !startPlaying
        pendingSeekMs = nil
        let adopted = reusingPreload ? takePreloadTask(for: track.fileID) : nil
        currentTrackGID = adopted != nil ? preloadTrackGID : trackGID(for: track)
        let request = LoadRequest(
            track: track,
            trackGID: currentTrackGID,
            positionMs: positionMs,
            sessionGeneration: session.sessionGeneration
        )
        loadTask = Task { [weak self] in
            await self?.runLoad(request, adopted: adopted)
        }
    }

    /// Everything one load attempt needs, captured before the `Task` that performs it starts, so
    /// the task never reads actor state that a newer load may already have replaced.
    private struct LoadRequest: Sendable {
        let track: AudioPlaybackSession.LoadedTrack
        let trackGID: [UInt8]
        let positionMs: UInt32
        let sessionGeneration: UInt64
    }

    /// Resolves the track's bytes, positions the decoder, and starts the pipeline.
    ///
    /// Every failure lands as one `.failed` pipeline event, which the reducer turns into an
    /// `.unavailable` report; Spirc then skips the track. The reason never carries the resolved
    /// CDN URL — see `AudioPipelineFailure`.
    private func runLoad(_ request: LoadRequest, adopted: Task<any AudioTrackByteSource, Error>?) async {
        do {
            let source: any AudioTrackByteSource
            if let adopted {
                source = try await adopted.value
            } else {
                source = try await sources.makeSource(
                    trackGID: request.trackGID,
                    fileID: request.track.fileID,
                    format: SpotifyAudioFormat(rawValue: request.track.format) ?? .oggVorbis160
                )
            }
            let totalLength = try await source.totalLength()
            try Task.checkCancellation()

            let startOffset = try await startOffset(
                in: source,
                totalLength: totalLength,
                positionMs: request.positionMs
            )
            try Task.checkCancellation()
            startPipeline(source: source, startOffset: startOffset, request: request)
        } catch is CancellationError {
            return
        } catch {
            enqueue(.failed(Self.failure(for: error)), request: request)
        }
    }

    /// The byte offset decoding starts at: the Ogg capture right after Spotify's fixed header
    /// for a load from the top, or the page containing `positionMs` for one that resumes
    /// mid-track (which is every reconnect rehydration and every transfer from another device).
    private func startOffset(
        in source: any AudioTrackByteSource,
        totalLength: Int,
        positionMs: UInt32
    ) async throws -> Int {
        let captureOffset = SpotifyTrackByteSource.oggStartOffset
        guard positionMs > 0 else { return captureOffset }
        let reader = DecodeByteSourceSeekReader(source: source, length: totalLength)
        let result = try await OggSeeker.byteOffset(
            forGranule: OggSeeker.granule(forMilliseconds: positionMs),
            in: reader,
            streamStart: captureOffset
        )
        return result.pageOffset
    }

    /// Installs the pipeline for `request` and starts it, unless a newer load has superseded it
    /// while the network work above was running.
    private func startPipeline(
        source: any AudioTrackByteSource,
        startOffset: Int,
        request: LoadRequest
    ) {
        guard session.current?.playRequestID == request.track.playRequestID else { return }
        let pipeline = makePipeline()
        self.pipeline = pipeline
        self.source = source

        output.start()
        pipeline.start(
            source: source,
            sink: output,
            startOffset: startOffset,
            startPositionMs: request.positionMs
        ) { [weak self] event in
            self?.enqueue(event, request: request)
        }
        if startsPaused {
            pipeline.pause()
        }
        if let pendingSeekMs {
            self.pendingSeekMs = nil
            seek(to: pendingSeekMs)
        }
    }

    /// Warms one track's key/resolve/first-chunk work ahead of the load that will need it.
    /// Nothing is decoded: Stage 1 preloads bytes, not audio.
    private func beginPreload(_ track: AudioPlaybackSession.LoadedTrack) {
        cancelPreload()
        let sources = self.sources
        let gid = trackGID(for: track)
        let format = SpotifyAudioFormat(rawValue: track.format) ?? .oggVorbis160
        preloadTrackGID = gid
        preload = (
            track.fileID,
            Task {
                let source = try await sources.makeSource(trackGID: gid, fileID: track.fileID, format: format)
                _ = try await source.totalLength()
                return source
            }
        )
    }

    private func cancelPreload() {
        preload?.task.cancel()
        preload = nil
        preloadTrackGID = []
    }

    /// Hands the preload task to a load for the same file, clearing the slot so it is not
    /// cancelled out from under the load that is now using it.
    private func takePreloadTask(for fileID: [UInt8]) -> Task<any AudioTrackByteSource, Error>? {
        guard let preload, preload.fileID == fileID else { return nil }
        self.preload = nil
        return preload.task
    }

    /// Converts a millisecond seek target into a page-aligned byte offset and hands it to the
    /// running pipeline, which picks it up between frames. A seek that arrives before the
    /// pipeline exists is held and replayed by `startPipeline`, rather than dropped.
    private func seek(to positionMs: UInt32) {
        guard let pipeline, let source, let track = session.current else {
            pendingSeekMs = positionMs
            return
        }
        let request = LoadRequest(
            track: track,
            trackGID: currentTrackGID,
            positionMs: positionMs,
            sessionGeneration: session.sessionGeneration
        )
        Task { [weak self] in
            await self?.performSeek(pipeline: pipeline, source: source, request: request)
        }
    }

    private func performSeek(
        pipeline: VorbisDecodePipeline,
        source: any AudioTrackByteSource,
        request: LoadRequest
    ) async {
        do {
            let totalLength = try await source.totalLength()
            // A seek to 0 still has to land on the first audio page, not on the header offset
            // it would otherwise short-circuit to, so it goes through the seeker like any other.
            let offset = try await startOffset(
                in: source,
                totalLength: totalLength,
                positionMs: max(request.positionMs, 1)
            )
            guard session.current?.playRequestID == request.track.playRequestID else { return }
            pipeline.seek(toByteOffset: offset, positionMs: request.positionMs)
        } catch {
            enqueue(.failed(Self.failure(for: error)), request: request)
        }
    }

    /// Stops the pipeline, the renderer, and any load work still in flight. The reducer has
    /// already moved to `.stopped`; this only releases what it was describing.
    private func teardown() {
        loadTask?.cancel()
        loadTask = nil
        preloadReportTask?.cancel()
        preloadReportTask = nil
        pendingSeekMs = nil
        pipeline?.stop()
        pipeline = nil
        source = nil
        currentTrackGID = []
        output.stop()
    }

    /// Sends one report to Rust, except `.timeToPreloadNext`, which waits until this track's
    /// file has actually finished downloading. Spirc reacts to that report by preloading the
    /// next track, and starting a second download while this one is still pulling bytes is what
    /// #208 asks this gate to prevent. It still fires at most once per load: the reducer has
    /// already latched it.
    private func sendReport(_ audioReport: AudioReport) {
        guard audioReport.kind == .timeToPreloadNext else {
            report(audioReport)
            return
        }
        guard let source else { return }
        preloadReportTask?.cancel()
        let send = report
        preloadReportTask = Task {
            guard (try? await source.downloadFully()) != nil, !Task.isCancelled else { return }
            send(audioReport)
        }
    }

    // MARK: - Pipeline events

    /// Applies one pipeline event and keeps the download ahead of the play position.
    private func apply(_ delivery: AudioPlaybackSession.PipelineEventDelivery) {
        perform(session.apply(pipelineEvent: delivery))
        guard case let .position(positionMs) = delivery.event, let source else { return }
        Task { await source.prefetchAhead(ofPositionMs: positionMs) }
    }

    /// Queues one pipeline event, stamped with the load it belongs to. Called from the decode
    /// thread; the reducer decides whether the stamp is still current.
    private nonisolated func enqueue(_ event: AudioPipelineEvent, request: LoadRequest) {
        inbox.yield(
            .pipelineEvent(
                AudioPlaybackSession.PipelineEventDelivery(
                    sessionGeneration: request.sessionGeneration,
                    playRequestID: request.track.playRequestID,
                    event: event
                )
            )
        )
    }

    /// The GID that arrived with the command currently being applied, or the one already in
    /// hand. A `load`/`preload` effect is always produced by the command that carried its GID.
    private func trackGID(for track: AudioPlaybackSession.LoadedTrack) -> [UInt8] {
        guard let pendingTrackGID, pendingTrackGID.playRequestID == track.playRequestID else {
            return currentTrackGID
        }
        return pendingTrackGID.gid
    }

    /// Maps a load-stage error onto the closed failure set. Nothing here is derived from a
    /// foreign error's description, which for the CDN path would carry a signed URL.
    private static func failure(for error: Error) -> AudioPipelineFailure {
        switch error {
        case is OggSeekError: .seekTargetNotFound
        default: .sourceUnavailable
        }
    }
}
