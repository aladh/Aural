//
//  OggSeek.swift
//  Aural
//
//  Time-based seek for the Ogg Vorbis decode path: Spirc seeks by millisecond, the decode
//  pipeline (a later slice) seeks only by byte offset, so this bisects the Ogg page stream for
//  the byte offset to restart decoding from. Pure logic; `OggByteReader` is the seam the CDN
//  fetcher/decryptor slice adapts, so this file never touches the network or a decryptor.
//

import Foundation

/// A random-access byte source over an Ogg stream. The later slice backs this with ranged CDN
/// fetches through the AES-CTR decryptor; checks back it with an in-memory buffer.
public protocol OggByteReader: Sendable {
    func read(offset: Int, length: Int) async throws -> Data
    var length: Int { get }
}

public struct OggSeekResult: Equatable, Sendable {
    /// Byte offset of the start of the page ("OggS") to restart Vorbis decode from.
    public let pageOffset: Int
    /// That page's granule position: the absolute PCM sample count at its end.
    public let granulePosition: UInt64

    public init(pageOffset: Int, granulePosition: UInt64) {
        self.pageOffset = pageOffset
        self.granulePosition = granulePosition
    }
}

public enum OggSeekError: Error, Equatable {
    /// No Ogg page (capture pattern) could be found in the searched range.
    case noPagesFound
    /// A page header was found but never completed even after reading to the end of the stream.
    case truncatedPage
    /// The underlying `OggByteReader` threw while satisfying a read.
    case readerFailed
}

public enum OggSeeker {
    /// Converts a millisecond position to a granule (absolute PCM sample count) at `sampleRate`.
    public static func granule(forMilliseconds ms: UInt32, sampleRate: UInt32 = 44_100) -> UInt64 {
        UInt64(ms) * UInt64(sampleRate) / 1000
    }

    /// The inverse of `granule(forMilliseconds:sampleRate:)`.
    public static func milliseconds(forGranule granule: UInt64, sampleRate: UInt32 = 44_100) -> UInt32 {
        UInt32(granule * 1000 / UInt64(sampleRate))
    }

    /// The start offset of the last page whose granule position is `<= target`, so decoding
    /// restarted there reaches `target` without skipping audio. Bisects `[streamStart, length)`
    /// by granule position (monotonically increasing along the stream), narrowing until the
    /// interval is smaller than `probe`, then scans pages linearly forward from the narrowed
    /// lower bound to pick the exact page. A page with an unknown granule position (-1, "no
    /// packet ends on this page") cannot be compared against `target`, so it is treated as
    /// uninformative and the bisection looks further ahead instead of narrowing on it. A target
    /// beyond the last page's granule clamps to the last page.
    public static func byteOffset(
        forGranule target: UInt64,
        sampleRate: UInt32 = 44_100,
        in reader: some OggByteReader,
        streamStart: Int,
        probe: Int = 64 * 1024,
        maxIterations: Int = 32
    ) async throws -> OggSeekResult {
        let length = reader.length
        guard streamStart < length else { throw OggSeekError.noPagesFound }

        var low = streamStart
        var high = length
        var iterations = 0

        // Bisect until the remaining interval is small enough to scan directly. Invariant: every
        // known-granule page strictly before `low` is `<= target` (or `low == streamStart`), and
        // every known-granule page at or after `high` is `> target` (or `high == length`).
        while high - low > probe, iterations < maxIterations {
            iterations += 1
            let mid = low + (high - low) / 2
            guard let page = try await firstPage(in: reader, atOrAfter: mid, probe: probe, hardLimit: length) else {
                // No page starts in [mid, length): the answer must be before mid.
                high = mid
                continue
            }
            guard let granule = knownGranule(page.header) else {
                // Unknown granule: uninformative, so look further ahead without narrowing `high`.
                low = page.offset + 1
                continue
            }
            if granule <= target {
                low = page.offset
            } else {
                high = page.offset
            }
        }

        // Final linear scan forward from `low`, which may not itself be page-aligned (the
        // unknown-granule branch above advances it by one byte), so realign onto the next real
        // page first. Keep the last page seen with a known granule `<= target`; stop as soon as
        // a page's known granule exceeds it.
        var best: OggSeekResult?
        var cursor = low
        while cursor < length {
            guard let page = try await firstPage(in: reader, atOrAfter: cursor, probe: probe, hardLimit: length) else {
                break
            }
            if let granule = knownGranule(page.header) {
                if granule <= target {
                    best = OggSeekResult(pageOffset: page.offset, granulePosition: granule)
                } else {
                    break
                }
            }
            let nextOffset = page.offset + page.header.totalLength
            guard nextOffset > page.offset else { break }  // guard against a zero-length page looping
            cursor = nextOffset
        }

        if let best { return best }

        // Nothing at or below target was found scanning forward from `low`: fall back to the
        // very first page in the stream (covers target below the first known granule).
        guard
            let fallbackPage = try await firstPage(
                in: reader,
                atOrAfter: streamStart,
                probe: probe,
                hardLimit: length
            )
        else {
            throw OggSeekError.noPagesFound
        }
        let granule = knownGranule(fallbackPage.header) ?? 0
        return OggSeekResult(pageOffset: fallbackPage.offset, granulePosition: granule)
    }

    /// The offset of the first page after the three Vorbis header packets (identification,
    /// comment, setup) whose granule position is not 0. stb_vorbis's pushdata API resyncs on any
    /// page, but a seek target before the first audio page is pointless — there is no audio
    /// there to decode — so decode must restart from here or later.
    public static func headerOffset(
        in reader: some OggByteReader,
        streamStart: Int,
        probe: Int = 64 * 1024
    ) async throws -> Int {
        var cursor = streamStart
        let length = reader.length
        while cursor < length {
            guard let page = try await parsePage(in: reader, at: cursor, probe: probe) else {
                throw OggSeekError.noPagesFound
            }
            if page.header.granulePosition != 0 {
                return page.offset
            }
            let nextOffset = page.offset + page.header.totalLength
            guard nextOffset > page.offset else { throw OggSeekError.truncatedPage }
            cursor = nextOffset
        }
        throw OggSeekError.noPagesFound
    }

    // MARK: - Page reading

    private struct LocatedPage {
        let offset: Int
        let header: OggPageHeader
    }

    /// Returns -1/unknown as nil, else the granule as `UInt64` (granule positions are never
    /// negative once known; only the "unknown" sentinel is negative).
    private static func knownGranule(_ header: OggPageHeader) -> UInt64? {
        header.granulePosition < 0 ? nil : UInt64(header.granulePosition)
    }

    /// Reads a `probe`-sized window at or after `from`, locates the first capture pattern in it,
    /// and parses the header there. Returns nil if no page starts within the probed range.
    private static func firstPage(
        in reader: some OggByteReader,
        atOrAfter from: Int,
        probe: Int,
        hardLimit: Int
    ) async throws -> LocatedPage? {
        guard from < hardLimit else { return nil }
        let windowLength = min(probe, hardLimit - from)
        let window = try await safeRead(reader, offset: from, length: windowLength)
        guard let captureOffset = OggPageHeader.nextCaptureOffset(in: window, from: 0) else { return nil }
        let pageOffset = from + captureOffset
        return try await parsePage(in: reader, at: pageOffset, probe: probe)
    }

    /// Parses the page starting exactly at `offset`, reading a `probe`-sized window and doubling
    /// it if the header or segment table is cut short by the window. Returns nil if `offset`
    /// isn't the start of a page at all (missing capture pattern); throws `truncatedPage` if the
    /// capture pattern is present but the header never completes even reading to the stream end.
    private static func parsePage(
        in reader: some OggByteReader,
        at offset: Int,
        probe: Int
    ) async throws -> LocatedPage? {
        let length = reader.length
        guard offset >= 0, offset < length else { return nil }
        var windowLength = min(probe, length - offset)
        var window = try await safeRead(reader, offset: offset, length: windowLength)

        while OggPageHeader.parse(window, at: 0) == nil {
            guard window.count >= 4, window.prefix(4).elementsEqual(OggPageHeader.capture) else {
                return nil
            }
            guard windowLength < length - offset else {
                throw OggSeekError.truncatedPage
            }
            windowLength = min(windowLength * 2, length - offset)
            window = try await safeRead(reader, offset: offset, length: windowLength)
        }

        guard let header = OggPageHeader.parse(window, at: 0) else { return nil }
        return LocatedPage(offset: offset, header: header)
    }

    private static func safeRead(_ reader: some OggByteReader, offset: Int, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        do {
            return try await reader.read(offset: offset, length: length)
        } catch {
            throw OggSeekError.readerFailed
        }
    }
}
