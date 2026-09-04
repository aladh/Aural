//
//  AudioPipelineEvent.swift
//  Aural
//
//  The one decode-pipeline event type for the Stage 1 audio path (#208). `VorbisDecodePipeline`
//  emits it; `AudioPlaybackSession` reduces it (as `AudioPlaybackSession.PipelineEvent`, which is
//  an alias for this). It used to be two near-identical enums, one per slice — a fact the
//  pipeline reported and a fact the reducer accepted had to be translated between, which is
//  exactly where a case gets dropped silently.
//
//  Owned by AuralDomain because the reducer is: the pipeline lives in the app target and may
//  depend on the domain, never the other way round.
//

import Foundation

/// Why a decode pipeline gave up on a track.
///
/// A closed set of stable cases rather than a stringified `Error`. The audio path's byte source
/// resolves signed CDN URLs whose query strings carry credentials (`__token__`, `verify`), and a
/// `String(describing:)` of whatever it threw would carry them into logs, the UI, and — through
/// an `Unavailable` report — Spotify Connect. Nothing here can.
public enum AudioPipelineFailure: String, Sendable, Equatable {
    /// The Vorbis headers never opened: not an Ogg stream, or truncated before the setup packet.
    case headerOpenFailed
    /// A seek's byte target has no page boundary within the search window.
    case seekTargetNotFound
    /// The Vorbis decoder rejected the stream mid-track.
    case decodeFailed
    /// The byte source failed or ran out: fetch error, decrypt error, or expired CDN URL.
    case sourceUnavailable
}

/// One fact the decode pipeline reports inward about the track it is playing.
///
/// Distinct from the outward `AudioReport` the session emits toward Rust: these are observations
/// from the decoder, not statements to Spirc. Position throttling (at most one `.position` every
/// 200 ms) is the pipeline's job; every `.position` that reaches
/// `AudioPlaybackSession.apply(pipelineEvent:)` produces a report.
public enum AudioPipelineEvent: Sendable, Equatable {
    case playing
    case paused
    case position(UInt32)
    case seeked(UInt32)
    case endOfTrack
    case stopped
    case failed(AudioPipelineFailure)
    /// The track's duration, once the caller knows it — from the load command's metadata, not
    /// from the decoder, which learns it only by reaching the end.
    case durationKnown(UInt32)
}
