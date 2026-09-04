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

/// Privacy-safe classification of what failed.
///
/// Never carries the underlying error's description: a CDN-backed byte source throws errors
/// whose messages embed signed URLs (`__token__`, `verify` query parameters), which must not
/// reach logs, the UI, or — through an `Unavailable` report — Spotify Connect.
public enum AudioPipelineFailure: Sendable, Equatable {
    /// The byte source's `read` threw: fetch error, decrypt error, or an expired CDN URL.
    case sourceRead
    /// The Vorbis headers never opened.
    case headers
    /// The stream opened but is not 44.1 kHz stereo.
    case unsupportedFormat
    /// The decoder threw once the stream was already open.
    case decode
    /// A seek's target byte offset had no real Ogg page within the search cap.
    case seek
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
