//
//  OggVorbisDecoder.swift
//  Spotty
//
//  Wraps stb_vorbis's "pushdata" streaming API (see Vendor/stb_vorbis/UPSTREAM.md) so premium
//  Ogg Vorbis audio can be decoded from bytes as they arrive over the network, with no Apple
//  framework involved -- AVFoundation/AudioToolbox do not decode Vorbis. Stage 1 of #201; nothing
//  here is wired into playback yet, so no caller exists on the real decode thread.
//
//  Thread safety: an `stb_vorbis` handle is not thread-safe (see stb_vorbis.c's own "THREAD
//  SAFETY" note), and this wrapper adds none of its own. It must be owned and driven by a single
//  thread end to end. `AudioRenderer.writeAudioData` already parks its Rust caller on backpressure
//  rather than decoding itself, so a later slice runs this on a dedicated decode thread, not on
//  the render queue or the main actor.
//

import CVorbis
import Foundation

public enum OggVorbisDecoderError: Error, Sendable, Equatable {
    /// `stb_vorbis_open_pushdata` needs a larger prefix of the file from the start; not a
    /// decode failure. Matches `VORBIS_need_more_data` (stb_vorbis.c's `STBVorbisError`, value
    /// 1) by raw value rather than by imported case name -- a plain C enum with no NS_ENUM-style
    /// annotation, so the exact Swift-imported spelling of that case is unconfirmed on this
    /// machine (no swift build was run; see the PR description).
    case needMoreData
    /// `stb_vorbis_open_pushdata` failed for a reason other than needing more data; carries the
    /// raw `STBVorbisError` code.
    case open(Int32)
    /// The stream opened but is not 44.1 kHz stereo, the only format `AudioRenderer` accepts.
    case unsupportedFormat(sampleRate: UInt32, channels: Int)
    /// A decode or flush call was made before headers were opened successfully.
    case notOpen
}

/// Streaming Ogg Vorbis decoder over stb_vorbis's pushdata API. Not `Sendable`; see the file-level
/// thread-safety note.
public final class OggVorbisDecoder {
    /// `STBVorbisError.VORBIS_need_more_data` (stb_vorbis.c), by raw value -- see
    /// `OggVorbisDecoderError.needMoreData`.
    private static let needMoreDataErrorCode: Int32 = 1

    private var handle: OpaquePointer?

    /// Set once `openHeaders` succeeds. Spotty's `AudioRenderer` is fixed 44.1 kHz stereo
    /// Float32 interleaved, so this decoder requires exactly that and never resamples or
    /// remixes channels.
    public private(set) var sampleRate: UInt32 = 0
    public private(set) var channels: Int = 0

    public init() {}

    deinit {
        if let handle {
            stb_vorbis_close(handle)
        }
    }

    /// Feeds the initial bytes of the file (from its first `"OggS"` capture pattern -- see
    /// `OggPageHeader` for where that sits in a decrypted Spotify track) to stb_vorbis so it can
    /// parse the Ogg/Vorbis headers. Returns the number of bytes consumed on success; the caller
    /// keeps whatever remains unconsumed for the next `decodeFrame` call.
    ///
    /// Throws `.needMoreData` when `bytes` is not yet a large enough prefix of the file -- the
    /// caller must call again from the start of the file with a larger buffer, not with only the
    /// new bytes appended.
    public func openHeaders(_ bytes: UnsafeRawBufferPointer) throws(OggVorbisDecoderError) -> Int {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            throw .needMoreData
        }
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        var consumed: Int32 = 0
        var error: Int32 = 0
        guard let opened = stb_vorbis_open_pushdata(pointer, Int32(bytes.count), &consumed, &error, nil) else {
            if error == Self.needMoreDataErrorCode {
                throw .needMoreData
            }
            throw .open(error)
        }

        let info = stb_vorbis_get_info(opened)
        guard info.sample_rate == 44_100, info.channels == 2 else {
            stb_vorbis_close(opened)
            throw .unsupportedFormat(sampleRate: info.sample_rate, channels: Int(info.channels))
        }

        handle = opened
        sampleRate = info.sample_rate
        channels = Int(info.channels)
        return Int(consumed)
    }

    /// Decodes as much of one Vorbis frame as `bytes` allows, appending interleaved stereo
    /// Float32 samples to `output` (replacing its prior contents).
    ///
    /// `consumed == 0` means stb_vorbis needs more bytes before it can make progress; the caller
    /// must feed a buffer that includes these same bytes plus more appended. `frames == 0` with
    /// `consumed > 0` means a header/skip page was consumed with no audio to show for it yet
    /// (this happens at least once right after `openHeaders`, since Vorbis always discards its
    /// first frame) -- keep calling.
    public func decodeFrame(
        _ bytes: UnsafeRawBufferPointer,
        into output: inout [Float]
    ) throws(OggVorbisDecoderError) -> (consumed: Int, frames: Int) {
        guard let handle else { throw .notOpen }
        output.removeAll(keepingCapacity: true)

        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            return (0, 0)
        }
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        var decodedChannels: Int32 = 0
        var samples: Int32 = 0
        var channelBuffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
        let consumed = stb_vorbis_decode_frame_pushdata(
            handle,
            pointer,
            Int32(bytes.count),
            &decodedChannels,
            &channelBuffers,
            &samples
        )

        guard samples > 0, let channelBuffers, let left = channelBuffers[0], let right = channelBuffers[1] else {
            return (Int(consumed), 0)
        }

        let frameCount = Int(samples)
        output.reserveCapacity(frameCount * 2)
        for frame in 0..<frameCount {
            output.append(left[frame])
            output.append(right[frame])
        }
        return (Int(consumed), frameCount)
    }

    /// Tells stb_vorbis the next data fed to `decodeFrame` is not contiguous with what came
    /// before (i.e. the caller seeked). The caller must then resume feeding from a byte offset
    /// found via `OggPageHeader.nextCaptureOffset` -- stb_vorbis resynchronizes on the next
    /// `"OggS"` page boundary it sees and starts decoding the frame *after* that.
    public func flush() {
        guard let handle else { return }
        stb_vorbis_flush_pushdata(handle)
    }

    /// The last error stb_vorbis recorded for this handle (clears it as a side effect, per
    /// `stb_vorbis_get_error`'s own contract). Zero (`VORBIS__no_error`) before anything failed.
    public var lastError: Int32 {
        guard let handle else { return 0 }
        return stb_vorbis_get_error(handle)
    }
}
