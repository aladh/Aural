//
//  ProtobufChecks.swift
//  Spotty
//

import Foundation
import SpottyDomain

func runProtobufChecks(_ check: CheckRunner) {
    check.suite("Protobuf codec") {
        for value: UInt64 in [0, 1, 127, 128, 16_383, 16_384, UInt64.max] {
            var writer = ProtobufWriter()
            writer.varint(field: 1, value)
            check.equal("varint round trip \(value)", ProtobufReader.firstVarint(field: 1, in: writer.data), value)
        }

        var mixed = ProtobufWriter()
        mixed.string(field: 1, "granted")
        mixed.varint(field: 2, 3_600)
        mixed.message(field: 3) { nested in
            nested.bytes(field: 1, Data([0xAA, 0xBB]))
        }
        check.equal("string field", ProtobufReader.firstBytes(field: 1, in: mixed.data), Data("granted".utf8))
        check.equal("varint field", ProtobufReader.firstVarint(field: 2, in: mixed.data), 3_600)
        // Field 3 carries an encoded submessage, so its contents are decoded one level down.
        let embedded = ProtobufReader.firstBytes(field: 3, in: mixed.data)
        check.notNil("embedded message present", embedded)
        if let embedded {
            check.equal(
                "embedded message decodes",
                ProtobufReader.firstBytes(field: 1, in: embedded),
                Data([0xAA, 0xBB])
            )
        }
        check.nil_("absent field", ProtobufReader.firstVarint(field: 9, in: mixed.data))

        var repeated = ProtobufWriter()
        for uri in ["spotify:track:a", "spotify:track:b", "spotify:track:c"] {
            repeated.string(field: 2, uri)
        }
        let uris = ProtobufReader.fields(in: repeated.data).compactMap(\.bytesPayload)
        check.equal(
            "repeated fields stay in order",
            uris.map { String(decoding: $0, as: UTF8.self) },
            ["spotify:track:a", "spotify:track:b", "spotify:track:c"]
        )

        var double = ProtobufWriter()
        double.double(field: 1, 123.456)
        check.notNil("fixed-64 double", ProtobufReader.firstDouble(field: 1, in: double.data))
        if let decoded = ProtobufReader.firstDouble(field: 1, in: double.data) {
            check.equal("double value", Int(decoded.rounded()), 123)
        }
        // A fixed-64 payload is nine bytes; anything shorter parses as finished.
        check.check("truncated fixed-64 is tolerated", ProtobufReader.fields(in: double.data.prefix(5)).isEmpty)

        // A varint cut off mid-continuation is a finished read, not a crash.
        var cutVarint = ProtobufWriter()
        cutVarint.varint(field: 1, 300)
        check.check(
            "truncated varint stops the read",
            ProtobufReader.fields(in: cutVarint.data.prefix(2)).isEmpty
        )

        // A length naming more bytes than remain must not read past the buffer.
        check.check(
            "declared length past the end stops the read",
            ProtobufReader.fields(in: Data([0x12, 0x05, 0x61])).isEmpty
        )

        // Groups died with proto2 and wire types 6 and 7 were never defined.
        for hostileTag: UInt8 in [0x0B, 0x0F] {
            check.check(
                "unknown wire type \(hostileTag) stops the read",
                ProtobufReader.fields(in: Data([hostileTag])).isEmpty
            )
        }

        // Ten bytes fill a UInt64. Shared decoder: field 1, wire type 0, then nine
        // saturated chunks and a tenth byte. Payload 0 or 1 at shift 63 is valid;
        // 2...127 and any tenth-byte continuation must fail closed.
        let nineSaturatedChunks = Data(repeating: 0xFF, count: 9)
        func field1Varint(_ trailing: [UInt8]) -> Data {
            Data([0x08]) + nineSaturatedChunks + Data(trailing)
        }

        check.equal(
            "ten-byte varint decodes to UInt64.max",
            ProtobufReader.firstVarint(field: 1, in: field1Varint([0x01])),
            UInt64.max
        )
        check.equal(
            "ten-byte varint with a clear high bit stays in range",
            ProtobufReader.firstVarint(field: 1, in: field1Varint([0x00])),
            UInt64.max >> 1
        )

        for payload: UInt8 in 0x02...0x7F {
            check.nil_(
                "tenth-byte terminal payload 0x\(String(payload, radix: 16)) overflows",
                ProtobufReader.firstVarint(field: 1, in: field1Varint([payload]))
            )
        }

        for continuation: UInt8 in [0x80, 0x81, 0xFF] {
            check.check(
                "tenth-byte continuation 0x\(String(continuation, radix: 16)) stops the read",
                ProtobufReader.fields(in: field1Varint([continuation])).isEmpty
            )
            check.check(
                "eleventh byte after 0x\(String(continuation, radix: 16)) stops the read",
                ProtobufReader.fields(in: field1Varint([continuation, 0x00])).isEmpty
            )
        }

        let overflowing = nineSaturatedChunks + Data([0x02])
        check.check(
            "overflowing tag varint stops the read",
            ProtobufReader.fields(in: overflowing).isEmpty
        )
        check.check(
            "overflowing length varint stops the read",
            ProtobufReader.fields(in: Data([0x0A]) + overflowing).isEmpty
        )

        // An accessor of one shape must ignore fields of another shape.
        var scalarOnly = ProtobufWriter()
        scalarOnly.varint(field: 1, 5)
        check.nil_(
            "bytes accessor skips varint fields",
            ProtobufReader.firstBytes(field: 1, in: scalarOnly.data)
        )
    }
}
