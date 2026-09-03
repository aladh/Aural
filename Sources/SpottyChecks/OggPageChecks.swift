//
//  OggPageChecks.swift
//  Spotty
//

import Foundation
import SpottyDomain

func runOggPageChecks(_ check: CheckRunner) {
    check.suite("Ogg page parsing") {
        // A synthetic page: capture pattern, version 0, beginning-of-stream flag, an "unknown"
        // granule position (all bits set, i.e. -1), serial/sequence/checksum, and three lacing
        // values (255, 255, 10 -> a 520-byte packet split across three segments).
        func littleEndianBytes(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }

        var page = Data("OggS".utf8)
        page.append(0)  // version
        page.append(0x02)  // flags: beginning of stream
        page.append(contentsOf: [UInt8](repeating: 0xFF, count: 8))  // granule position: -1
        page.append(littleEndianBytes(7))  // serial
        page.append(littleEndianBytes(3))  // sequence
        page.append(littleEndianBytes(0xDEAD_BEEF))  // checksum
        page.append(3)  // segment count
        page.append(contentsOf: [255, 255, 10])  // segment table
        page.append(Data(repeating: 0x41, count: 520))  // packet payload ("body")

        guard let header = OggPageHeader.parse(page, at: 0) else {
            check.check("synthetic page parses", false)
            return
        }

        check.equal("version", header.version, 0)
        check.check("continuation flag clear", !header.isContinuation)
        check.check("beginning-of-stream flag set", header.isBeginningOfStream)
        check.check("end-of-stream flag clear", !header.isEndOfStream)
        check.equal("granule position of all-set bits decodes to -1", header.granulePosition, -1)
        check.equal("serial number", header.serialNumber, 7)
        check.equal("sequence number", header.sequenceNumber, 3)
        check.equal("checksum", header.checksum, 0xDEAD_BEEF)
        check.equal("segment table", header.segmentTable, [255, 255, 10])
        check.equal("header length", header.headerLength, 30)
        check.equal("body length", header.bodyLength, 520)
        check.equal("total length", header.totalLength, 550)

        check.nil_(
            "truncated header (26 of 27 fixed bytes) fails to parse",
            OggPageHeader.parse(page.prefix(26), at: 0)
        )
        check.nil_(
            "header truncated inside the segment table fails to parse",
            OggPageHeader.parse(page.prefix(28), at: 0)
        )

        var wrongCapture = page
        wrongCapture[wrongCapture.startIndex] = UInt8(ascii: "X")
        check.nil_("wrong capture pattern fails to parse", OggPageHeader.parse(wrongCapture, at: 0))

        check.nil_("offset past the end of the buffer fails to parse", OggPageHeader.parse(page, at: page.count))
        check.nil_("negative offset fails to parse", OggPageHeader.parse(page, at: -1))

        // Scanning for the next capture pattern: some junk, a partial "Ogg" prefix that must not
        // false-positive, then a real page.
        var scan = Data("junk before the stream".utf8)
        let partialPrefixOffset = scan.count
        scan.append(Data("Og".utf8))  // partial capture pattern, must not match
        scan.append(Data("random filler".utf8))
        let realPageOffset = scan.count
        scan.append(page)

        check.equal(
            "nextCaptureOffset finds the real page, skipping the partial prefix",
            OggPageHeader.nextCaptureOffset(in: scan, from: 0),
            realPageOffset
        )
        check.equal(
            "nextCaptureOffset starting after the partial prefix still finds the real page",
            OggPageHeader.nextCaptureOffset(in: scan, from: partialPrefixOffset + 1),
            realPageOffset
        )
        check.equal(
            "nextCaptureOffset starting exactly at the real page finds it",
            OggPageHeader.nextCaptureOffset(in: scan, from: realPageOffset),
            realPageOffset
        )
        check.nil_(
            "nextCaptureOffset starting after the real page finds nothing",
            OggPageHeader.nextCaptureOffset(in: scan, from: realPageOffset + 1)
        )
        check.nil_(
            "nextCaptureOffset over data with no capture pattern finds nothing",
            OggPageHeader.nextCaptureOffset(in: Data("no capture pattern here".utf8), from: 0)
        )

        // nextValidPage: a false-positive "OggS" match whose own declared segment table (255
        // lacing bytes) does not fit before the buffer ends -- `parse` correctly rejects it --
        // immediately followed by a real, minimal page. A plain substring search (the old
        // `captureOffsetAtOrAfter` this replaced) would have returned the false match's offset
        // without ever checking it actually parses; `nextValidPage` must instead skip past it.
        var falseMatch = Data("OggS".utf8)
        falseMatch.append(0)  // version
        falseMatch.append(0)  // flags
        falseMatch.append(contentsOf: [UInt8](repeating: 0, count: 8))  // granule position: 0
        falseMatch.append(littleEndianBytes(1))  // serial
        falseMatch.append(littleEndianBytes(1))  // sequence
        falseMatch.append(littleEndianBytes(0))  // checksum
        falseMatch.append(255)  // segment count: claims 255 lacing bytes follow

        var minimalRealPage = Data("OggS".utf8)
        minimalRealPage.append(0)  // version
        minimalRealPage.append(0)  // flags
        minimalRealPage.append(contentsOf: [UInt8](repeating: 0, count: 8))  // granule position: 0
        minimalRealPage.append(littleEndianBytes(42))  // serial
        minimalRealPage.append(littleEndianBytes(1))  // sequence
        minimalRealPage.append(littleEndianBytes(0))  // checksum
        minimalRealPage.append(1)  // segment count
        minimalRealPage.append(0)  // one zero-length lacing value

        var falsePositiveThenRealPage = falseMatch
        let realMinimalPageOffset = falsePositiveThenRealPage.count
        falsePositiveThenRealPage.append(minimalRealPage)

        check.nil_(
            "the false match alone (255-byte segment table claimed, nothing follows) never parses",
            OggPageHeader.parse(falsePositiveThenRealPage.prefix(realMinimalPageOffset), at: 0)
        )

        let resynced = OggPageHeader.nextValidPage(in: falsePositiveThenRealPage, from: 0)
        check.equal(
            "nextValidPage skips the false match to the real page after it",
            resynced?.offset,
            realMinimalPageOffset
        )
        check.equal("nextValidPage returns the real page's header", resynced?.header.serialNumber, 42)

        check.nil_(
            "nextValidPage finds nothing when the only capture pattern in range never parses",
            OggPageHeader.nextValidPage(in: falsePositiveThenRealPage.prefix(realMinimalPageOffset), from: 0)
        )
    }
}
