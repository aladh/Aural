import Testing
//
//  ProtobufChecks.swift
//  Spotty
//

import Foundation
import SpottyDomain

@Test
func testProtobuf() {
    do {
        for value: UInt64 in [0, 1, 127, 128, 16_383, 16_384, UInt64.max] {
            var writer = ProtobufWriter()
            writer.varint(field: 1, value)
            #expect((ProtobufReader.firstVarint(field: 1, in: writer.data)) == (value), "varint round trip \(value)")
        }

        var mixed = ProtobufWriter()
        mixed.string(field: 1, "granted")
        mixed.varint(field: 2, 3_600)
        mixed.message(field: 3) { nested in
            nested.bytes(field: 1, Data([0xAA, 0xBB]))
        }
        #expect((ProtobufReader.firstBytes(field: 1, in: mixed.data)) == (Data("granted".utf8)), "string field")
        #expect((ProtobufReader.firstVarint(field: 2, in: mixed.data)) == (3_600), "varint field")
        // Field 3 carries an encoded submessage, so its contents are decoded one level down.
        let embedded = ProtobufReader.firstBytes(field: 3, in: mixed.data)
        #expect((embedded) != nil, "embedded message present")
        if let embedded {
            #expect(
                (ProtobufReader.firstBytes(field: 1, in: embedded)) == (Data([0xAA, 0xBB])), "embedded message decodes")
        }
        #expect((ProtobufReader.firstVarint(field: 9, in: mixed.data)) == nil, "absent field")

        var repeated = ProtobufWriter()
        for uri in ["spotify:track:a", "spotify:track:b", "spotify:track:c"] {
            repeated.string(field: 2, uri)
        }
        let uris = ProtobufReader.fields(in: repeated.data).compactMap(\.bytesPayload)
        #expect(
            (uris.map { String(decoding: $0, as: UTF8.self) })
                == (["spotify:track:a", "spotify:track:b", "spotify:track:c"]), "repeated fields stay in order")

        var double = ProtobufWriter()
        double.double(field: 1, 123.456)
        #expect((ProtobufReader.firstDouble(field: 1, in: double.data)) != nil, "fixed-64 double")
        if let decoded = ProtobufReader.firstDouble(field: 1, in: double.data) {
            #expect((Int(decoded.rounded())) == (123), "double value")
        }
        // A fixed-64 payload is nine bytes; anything shorter parses as finished.
        #expect((ProtobufReader.fields(in: double.data.prefix(5)).isEmpty) == true, "truncated fixed-64 is tolerated")

        // A varint cut off mid-continuation is a finished read, not a crash.
        var cutVarint = ProtobufWriter()
        cutVarint.varint(field: 1, 300)
        #expect(
            (ProtobufReader.fields(in: cutVarint.data.prefix(2)).isEmpty) == true, "truncated varint stops the read")

        // A length naming more bytes than remain must not read past the buffer.
        #expect(
            (ProtobufReader.fields(in: Data([0x12, 0x05, 0x61])).isEmpty) == true,
            "declared length past the end stops the read")

        // Groups died with proto2 and wire types 6 and 7 were never defined.
        for hostileTag: UInt8 in [0x0B, 0x0F] {
            #expect(
                (ProtobufReader.fields(in: Data([hostileTag])).isEmpty) == true,
                "unknown wire type \(hostileTag) stops the read")
        }

        // Ten bytes fill a UInt64. Shared decoder: field 1, wire type 0, then nine
        // saturated chunks and a tenth byte. Payload 0 or 1 at shift 63 is valid;
        // 2...127 and any tenth-byte continuation must fail closed.
        let nineSaturatedChunks = Data(repeating: 0xFF, count: 9)
        func field1Varint(_ trailing: [UInt8]) -> Data {
            Data([0x08]) + nineSaturatedChunks + Data(trailing)
        }

        #expect(
            (ProtobufReader.firstVarint(field: 1, in: field1Varint([0x01]))) == (UInt64.max),
            "ten-byte varint decodes to UInt64.max")
        #expect(
            (ProtobufReader.firstVarint(field: 1, in: field1Varint([0x00]))) == (UInt64.max >> 1),
            "ten-byte varint with a clear high bit stays in range")

        for payload: UInt8 in 0x02...0x7F {
            #expect(
                (ProtobufReader.firstVarint(field: 1, in: field1Varint([payload]))) == nil,
                "tenth-byte terminal payload 0x\(String(payload, radix: 16)) overflows")
        }

        for continuation: UInt8 in [0x80, 0x81, 0xFF] {
            #expect(
                (ProtobufReader.fields(in: field1Varint([continuation])).isEmpty) == true,
                "tenth-byte continuation 0x\(String(continuation, radix: 16)) stops the read")
            #expect(
                (ProtobufReader.fields(in: field1Varint([continuation, 0x00])).isEmpty) == true,
                "eleventh byte after 0x\(String(continuation, radix: 16)) stops the read")
        }

        let overflowing = nineSaturatedChunks + Data([0x02])
        #expect((ProtobufReader.fields(in: overflowing).isEmpty) == true, "overflowing tag varint stops the read")
        #expect(
            (ProtobufReader.fields(in: Data([0x0A]) + overflowing).isEmpty) == true,
            "overflowing length varint stops the read")

        // An accessor of one shape must ignore fields of another shape.
        var scalarOnly = ProtobufWriter()
        scalarOnly.varint(field: 1, 5)
        #expect((ProtobufReader.firstBytes(field: 1, in: scalarOnly.data)) == nil, "bytes accessor skips varint fields")
    }
}
