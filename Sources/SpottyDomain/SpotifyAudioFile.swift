//
//  SpotifyAudioFile.swift
//  Spotty
//
//  Parses the fixed-size header librespot prepends to a decrypted Spotify audio file, and
//  names the audio formats Spotify's storage-resolve response can offer.
//

import Foundation

/// Spotify's audio-file encodings, matching librespot's `AudioFileFormat` numbering exactly —
/// these values arrive over the wire as `StorageResolveResponse` file-format tags.
public enum SpotifyAudioFormat: UInt8, Sendable {
    case oggVorbis96 = 0
    case oggVorbis160 = 1
    case oggVorbis320 = 2
    case mp3_256 = 3
    case mp3_320 = 4
    case mp3_160 = 5
    case mp3_96 = 6
    case mp3_160Enc = 7
    case aac24 = 8
    case aac48 = 9
    case flac = 16

    public var isOggVorbis: Bool {
        switch self {
        case .oggVorbis96, .oggVorbis160, .oggVorbis320: true
        default: false
        }
    }

    /// The format's nominal bitrate, or `nil` for FLAC, which is not a constant-bitrate codec.
    public var kilobitsPerSecond: Int? {
        switch self {
        case .oggVorbis96: 96
        case .oggVorbis160: 160
        case .oggVorbis320: 320
        case .mp3_256: 256
        case .mp3_320: 320
        case .mp3_160: 160
        case .mp3_96: 96
        case .mp3_160Enc: 160
        case .aac24: 24
        case .aac48: 48
        case .flac: nil
        }
    }

    /// `kilobitsPerSecond` converted to bytes per second (kbps / 8 * 1024), or `nil` for FLAC.
    public var bytesPerSecond: Int? {
        kilobitsPerSecond.map { $0 / 8 * 1024 }
    }
}

/// The fixed-size header librespot writes ahead of Ogg Vorbis capture in a decrypted Spotify
/// audio file: normalisation gain/peak as four little-endian `Float32`s at offset 144, followed
/// by the Ogg magic "OggS" at offset 0xa7 when the file carries an Ogg Vorbis stream.
///
/// Spotty currently plays with normalisation off (see `AudioRenderer`), so these gains are
/// parsed for future use but never applied to playback.
public struct SpotifyAudioHeader: Sendable, Equatable {
    /// Total header length in bytes, before audio capture begins.
    public static let length = 0xa7

    /// Byte offset of the first of the four normalisation `Float32` fields.
    public static let normalisationOffset = 144

    private static let oggMagic = Data("OggS".utf8)

    public let trackGainDB: Float
    public let trackPeak: Float
    public let albumGainDB: Float
    public let albumPeak: Float

    /// Parses the header from a file prefix. `prefix` need only contain the header itself;
    /// callers that also have the Ogg capture bytes may pass those along too, in which case
    /// the magic is checked.
    ///
    /// Returns `nil` when `prefix` is shorter than `length`, or when bytes `length..<length+4`
    /// are present but are not the Ogg magic "OggS".
    public static func parse(_ prefix: Data) -> SpotifyAudioHeader? {
        guard prefix.count >= length else { return nil }

        let base = prefix.startIndex
        let gainsStart = prefix.index(base, offsetBy: normalisationOffset)
        guard let trackGainDB = readFloat32LE(prefix, at: gainsStart),
            let trackPeak = readFloat32LE(prefix, at: prefix.index(gainsStart, offsetBy: 4)),
            let albumGainDB = readFloat32LE(prefix, at: prefix.index(gainsStart, offsetBy: 8)),
            let albumPeak = readFloat32LE(prefix, at: prefix.index(gainsStart, offsetBy: 12))
        else { return nil }

        let magicEnd = prefix.index(base, offsetBy: length + oggMagic.count, limitedBy: prefix.endIndex)
        if let magicEnd {
            let magicStart = prefix.index(base, offsetBy: length)
            guard prefix[magicStart..<magicEnd] == oggMagic else { return nil }
        }

        return SpotifyAudioHeader(
            trackGainDB: trackGainDB,
            trackPeak: trackPeak,
            albumGainDB: albumGainDB,
            albumPeak: albumPeak
        )
    }

    /// Whether `data` carries the Ogg magic "OggS" at the expected offset right after the header.
    public static func hasOggCapture(_ data: Data) -> Bool {
        let base = data.startIndex
        guard let magicStart = data.index(base, offsetBy: length, limitedBy: data.endIndex),
            let magicEnd = data.index(magicStart, offsetBy: oggMagic.count, limitedBy: data.endIndex)
        else { return false }
        return data[magicStart..<magicEnd] == oggMagic
    }

    private static func readFloat32LE(_ data: Data, at index: Data.Index) -> Float? {
        guard let end = data.index(index, offsetBy: 4, limitedBy: data.endIndex) else { return nil }
        var bits: UInt32 = 0
        for (offset, byte) in data[index..<end].enumerated() {
            bits |= UInt32(byte) << (8 * offset)
        }
        return Float(bitPattern: bits)
    }
}
