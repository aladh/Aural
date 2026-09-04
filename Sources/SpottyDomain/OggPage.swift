//
//  OggPage.swift
//  Spotty
//
//  Pure Ogg container parsing: the physical page framing Vorbis packets travel in. No Vorbis
//  decoding happens here — that is CVorbis/OggVorbisDecoder, in SpottyCore. This layer exists so a
//  later seek slice can scan pages and pick a granule-position-bounded restart point without
//  touching the decoder.
//
//  Spotify layout: for a decrypted premium track, the first "OggS" capture pattern sits at byte
//  0xa7 of the file (the bytes before it are the Spotify-specific header/metadata that precedes
//  the Ogg stream). The Ogg granule position on a Vorbis stream is the absolute PCM sample count
//  at the stream's sample rate, which for Spotty is always 44.1 kHz (see
//  OggVorbisDecoder.unsupportedFormat). A later `seek(toMillisecond:)` is therefore: scan pages
//  for the last one whose granule position is <= target millisecond * 44.1, flush and restart
//  Vorbis decode from that page's capture offset, then drop decoded samples up to the exact
//  target so playback lands sample-accurate rather than page-accurate.
//

import Foundation

/// One parsed Ogg page header (the fixed fields plus the segment table; the packet payload
/// bytes that follow are not this type's concern).
public struct OggPageHeader: Equatable, Sendable {
    public let version: UInt8
    public let isContinuation: Bool
    public let isBeginningOfStream: Bool
    public let isEndOfStream: Bool
    /// Absolute PCM sample count at the end of this page, or -1 ("no packet finishes on this
    /// page") per the raw `UInt64` bit pattern reinterpreted as `Int64`.
    public let granulePosition: Int64
    public let serialNumber: UInt32
    public let sequenceNumber: UInt32
    public let checksum: UInt32
    /// Lacing values, one per segment in this page's body; each is 0...255 bytes of payload.
    public let segmentTable: [UInt8]

    /// The four-byte pattern that opens every Ogg page.
    public static let capture: [UInt8] = Array("OggS".utf8)

    /// Fixed header fields (27 bytes) plus the segment table.
    public var headerLength: Int { 27 + segmentTable.count }

    /// Sum of the segment table, i.e. the number of packet-payload bytes following the header.
    public var bodyLength: Int { segmentTable.reduce(0) { $0 + Int($1) } }

    public var totalLength: Int { headerLength + bodyLength }

    /// Parses one page header at `offset` into `data`. Returns nil if the capture pattern is
    /// missing at that offset, or if fewer than 27 bytes plus the declared segment table are
    /// available — a truncated buffer is indistinguishable from "keep reading" to every caller.
    public static func parse(_ data: Data, at offset: Int) -> OggPageHeader? {
        let start = data.startIndex + offset
        guard offset >= 0, data.distance(from: start, to: data.endIndex) >= 27 else { return nil }
        guard data[start..<(start + 4)].elementsEqual(capture) else { return nil }

        let version = data[start + 4]
        let flags = data[start + 5]
        let granuleRaw = littleEndianUInt64(data, at: start + 6)
        let serialNumber = littleEndianUInt32(data, at: start + 14)
        let sequenceNumber = littleEndianUInt32(data, at: start + 18)
        let checksum = littleEndianUInt32(data, at: start + 22)
        let segmentCount = Int(data[start + 26])

        let segmentTableStart = start + 27
        guard data.distance(from: segmentTableStart, to: data.endIndex) >= segmentCount else { return nil }
        let segmentTable = Array(data[segmentTableStart..<(segmentTableStart + segmentCount)])

        return OggPageHeader(
            version: version,
            isContinuation: flags & 0x01 != 0,
            isBeginningOfStream: flags & 0x02 != 0,
            isEndOfStream: flags & 0x04 != 0,
            granulePosition: Int64(bitPattern: granuleRaw),
            serialNumber: serialNumber,
            sequenceNumber: sequenceNumber,
            checksum: checksum,
            segmentTable: segmentTable
        )
    }

    /// The offset of the next `"OggS"` capture pattern at or after `offset`, or nil if none
    /// remains. Does not validate that a full page header follows — callers combine this with
    /// `parse(_:at:)` and keep scanning past a false-positive match.
    public static func nextCaptureOffset(in data: Data, from offset: Int) -> Int? {
        guard offset >= 0 else { return nil }
        let start = data.startIndex + offset
        guard start < data.endIndex else { return nil }
        let searchRange = start..<data.endIndex
        guard let firstByteRange = data.range(of: Data(capture), in: searchRange) else { return nil }
        return data.distance(from: data.startIndex, to: firstByteRange.lowerBound)
    }

    /// Finds the next page whose header actually parses at or after `offset`: scans for `"OggS"`
    /// via `nextCaptureOffset`, tries `parse(_:at:)` there, and on a false-positive match (the
    /// bytes happened to occur inside packet payload data, not a real page boundary) resumes the
    /// capture search one byte later instead of returning garbage. Returns nil once no further
    /// capture pattern remains.
    public static func nextValidPage(in data: Data, from offset: Int) -> (offset: Int, header: OggPageHeader)? {
        var searchFrom = offset
        while let captureOffset = nextCaptureOffset(in: data, from: searchFrom) {
            if let header = parse(data, at: captureOffset) {
                return (captureOffset, header)
            }
            searchFrom = captureOffset + 1
        }
        return nil
    }

    private static func littleEndianUInt64(_ data: Data, at index: Data.Index) -> UInt64 {
        var result: UInt64 = 0
        for offset in 0..<8 {
            result |= UInt64(data[index + offset]) << (8 * offset)
        }
        return result
    }

    private static func littleEndianUInt32(_ data: Data, at index: Data.Index) -> UInt32 {
        var result: UInt32 = 0
        for offset in 0..<4 {
            result |= UInt32(data[index + offset]) << (8 * offset)
        }
        return result
    }
}
