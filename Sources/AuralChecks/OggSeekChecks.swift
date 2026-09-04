//
//  OggSeekChecks.swift
//  Aural
//

import Foundation
import AuralDomain

/// An in-memory `OggByteReader` over a fixed buffer, counting reads so the checks below can
/// assert the bisection stays sub-linear in the page count.
private final class RecordingReader: OggByteReader, @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private(set) var readCount = 0

    init(_ data: Data) {
        self.data = data
    }

    var length: Int { data.count }

    func read(offset: Int, length: Int) async throws -> Data {
        lock.lock()
        readCount += 1
        lock.unlock()
        let start = data.startIndex + offset
        let end = min(data.endIndex, start + length)
        guard start >= data.startIndex, start <= data.endIndex else { return Data() }
        return Data(data[start..<end])
    }
}

private enum ReaderProbe: Error, Equatable {
    case boom
}

/// A reader that always throws, to check `OggSeekError.readerFailed` surfaces rather than the
/// underlying error.
private struct ThrowingReader: OggByteReader {
    let length: Int

    func read(offset: Int, length: Int) async throws -> Data {
        throw ReaderProbe.boom
    }
}

/// One recorded page in the synthetic fixture: its start offset and granule position, so
/// assertions below can reference exact expected results without re-deriving byte math.
private struct FixturePage {
    let offset: Int
    let granule: UInt64
}

/// Builds a synthetic Ogg stream: some leading non-Ogg bytes (as in the real Spotify layout,
/// where "OggS" first appears at byte 0xa7), then `headerPageCount` Vorbis header pages (granule
/// 0, single small segment each), then `audioPageCount` audio pages with a monotonically
/// increasing granule position, single-segment bodies under 255 bytes so no lacing continuation
/// is needed. The first audio page carries granule 0 too (a legitimate case: its packet does not
/// complete within the page), which is what makes "target 0" land on it rather than on the last
/// header page — both are tied at granule 0, and the first audio page is the later of the two in
/// stream order.
private func buildSyntheticStream(
    leadingJunk: Int = 100,
    headerPageCount: Int = 3,
    audioPageCount: Int = 200,
    granuleStep: UInt64 = 1024
) -> (data: Data, streamStart: Int, headerPages: [FixturePage], audioPages: [FixturePage]) {
    func littleEndianBytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
    func littleEndianBytes(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    func appendPage(to data: inout Data, granule: UInt64, bodySize: Int, sequence: UInt32, flags: UInt8) -> Int {
        let offset = data.count
        data.append(Data("OggS".utf8))
        data.append(0)  // version
        data.append(flags)
        data.append(littleEndianBytes(granule))
        data.append(littleEndianBytes(UInt32(1)))  // serial number: one logical stream
        data.append(littleEndianBytes(sequence))
        data.append(littleEndianBytes(UInt32(0)))  // checksum: unverified by OggPageHeader.parse
        data.append(1)  // segment count: one segment, no lacing continuation
        data.append(UInt8(bodySize))
        data.append(Data(repeating: 0x41, count: bodySize))
        return offset
    }

    var data = Data(repeating: 0xa7, count: leadingJunk)
    let streamStart = data.count
    var sequence: UInt32 = 0
    var headerPages: [FixturePage] = []
    for i in 0..<headerPageCount {
        let flags: UInt8 = i == 0 ? 0x02 : 0  // first header page is beginning-of-stream
        let offset = appendPage(to: &data, granule: 0, bodySize: 4, sequence: sequence, flags: flags)
        headerPages.append(FixturePage(offset: offset, granule: 0))
        sequence += 1
    }

    var audioPages: [FixturePage] = []
    for i in 0..<audioPageCount {
        let granule = UInt64(i) * granuleStep
        let bodySize = 100 + (i % 10) * 10  // varying, always well under 255
        let flags: UInt8 = i == audioPageCount - 1 ? 0x04 : 0  // last page is end-of-stream
        let offset = appendPage(to: &data, granule: granule, bodySize: bodySize, sequence: sequence, flags: flags)
        audioPages.append(FixturePage(offset: offset, granule: granule))
        sequence += 1
    }

    return (data, streamStart, headerPages, audioPages)
}

func runOggSeekChecks(_ check: CheckRunner) async {
    await check.suite("Ogg granule bisection") {
        check.equal("granule at 0ms", OggSeeker.granule(forMilliseconds: 0), 0)
        check.equal("granule at 1000ms and 44.1kHz", OggSeeker.granule(forMilliseconds: 1_000), 44_100)
        check.equal(
            "milliseconds is the inverse of granule",
            OggSeeker.milliseconds(forGranule: OggSeeker.granule(forMilliseconds: 5_000)),
            5_000
        )

        let fixture = buildSyntheticStream()
        // A small probe relative to the fixture's ~35 KB size, so bisection narrows through
        // several rounds instead of the interval already being under one probe window (the real
        // 64 KiB default is sized for full-length CDN tracks, not this compact in-memory fixture).
        let probe = 2048

        // Exact target on a page boundary returns that page.
        let midAudioPage = fixture.audioPages[100]
        await expectSeek(
            check,
            "exact target on a page boundary returns that page",
            target: midAudioPage.granule,
            fixture: fixture,
            probe: probe,
            expectedOffset: midAudioPage.offset,
            expectedGranule: midAudioPage.granule
        )

        // A target strictly between two pages returns the earlier page.
        let nextAudioPage = fixture.audioPages[101]
        check.check(
            "fixture has room between page 100 and 101 for a between-pages target",
            nextAudioPage.granule - midAudioPage.granule > 1
        )
        await expectSeek(
            check,
            "target between pages returns the earlier page",
            target: midAudioPage.granule + 1,
            fixture: fixture,
            probe: probe,
            expectedOffset: midAudioPage.offset,
            expectedGranule: midAudioPage.granule
        )

        // Target 0 returns the first audio page: it ties with the header pages at granule 0, and
        // is the later of the two in stream order.
        let firstAudioPage = fixture.audioPages[0]
        check.equal("first audio page granule is 0", firstAudioPage.granule, 0)
        await expectSeek(
            check,
            "target 0 returns the first audio page",
            target: 0,
            fixture: fixture,
            probe: probe,
            expectedOffset: firstAudioPage.offset,
            expectedGranule: 0
        )

        // A target past the last page's granule clamps to the last page.
        let lastAudioPage = fixture.audioPages[fixture.audioPages.count - 1]
        await expectSeek(
            check,
            "target past the end clamps to the last page",
            target: lastAudioPage.granule + 1_000_000,
            fixture: fixture,
            probe: probe,
            expectedOffset: lastAudioPage.offset,
            expectedGranule: lastAudioPage.granule
        )

        // A stream with no capture pattern anywhere throws noPagesFound.
        let noCapture = RecordingReader(Data(repeating: 0x00, count: 4_096))
        await expectThrows(
            check,
            "a stream with no capture pattern throws noPagesFound",
            OggSeekError.noPagesFound
        ) {
            _ = try await OggSeeker.byteOffset(forGranule: 0, in: noCapture, streamStart: 0, probe: probe)
        }

        // A reader that throws surfaces readerFailed, not the underlying error.
        let throwingReader = ThrowingReader(length: fixture.data.count)
        await expectThrows(
            check,
            "a reader that throws surfaces readerFailed",
            OggSeekError.readerFailed
        ) {
            _ = try await OggSeeker.byteOffset(
                forGranule: midAudioPage.granule,
                in: throwingReader,
                streamStart: fixture.streamStart,
                probe: probe
            )
        }

        // headerOffset returns the first page after the header pages whose granule isn't 0 —
        // here, the second audio page (the first audio page ties with the headers at granule 0).
        let reader = RecordingReader(fixture.data)
        do {
            let offset = try await OggSeeker.headerOffset(in: reader, streamStart: fixture.streamStart, probe: probe)
            check.equal("headerOffset lands on the first non-zero-granule page", offset, fixture.audioPages[1].offset)
        } catch {
            check.check("headerOffset succeeds, got \(error)", false)
        }
    }
}

private func expectSeek(
    _ check: CheckRunner,
    _ label: String,
    target: UInt64,
    fixture: (data: Data, streamStart: Int, headerPages: [FixturePage], audioPages: [FixturePage]),
    probe: Int,
    expectedOffset: Int,
    expectedGranule: UInt64
) async {
    let reader = RecordingReader(fixture.data)
    do {
        let result = try await OggSeeker.byteOffset(
            forGranule: target,
            in: reader,
            streamStart: fixture.streamStart,
            probe: probe
        )
        check.equal("\(label): page offset", result.pageOffset, expectedOffset)
        check.equal("\(label): granule position", result.granulePosition, expectedGranule)
        let totalPages = fixture.headerPages.count + fixture.audioPages.count
        check.check(
            "\(label): read count (\(reader.readCount)) stays well below the page count (\(totalPages))",
            reader.readCount <= 40
        )
    } catch {
        check.check("\(label) succeeds, got \(error)", false)
    }
}

private func expectThrows(
    _ check: CheckRunner,
    _ label: String,
    _ expected: OggSeekError,
    perform: () async throws -> Void
) async {
    do {
        try await perform()
        check.check("\(label)", false)
    } catch let error as OggSeekError {
        check.equal(label, error, expected)
    } catch {
        check.check("\(label): expected OggSeekError, got \(error)", false)
    }
}
