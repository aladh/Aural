import Testing
//
//  StorageResolveChecks.swift
//  Spotty
//

import SpottyDomain
import Foundation

@Suite("Storage Resolve")
struct StorageResolveTests {
    @Test
    func testStorageResolve() {
        do {
            var cdn = ProtobufWriter()
            cdn.varint(field: 1, 0)
            cdn.string(field: 2, "https://audio-ak.spotifycdn.com/a")
            cdn.string(field: 2, "https://audio-ak.spotifycdn.com/b")
            cdn.bytes(field: 4, Data([0x01, 0x02, 0x03, 0x04]))
            cdn.varint(field: 99, 42)  // unknown field: must be skipped, not misread as a known one.

            let decodedCDN = StorageResolveResponse(protobuf: cdn.data)
            #expect((decodedCDN.result) == (.cdn), "cdn result decodes")
            #expect(
                (decodedCDN.cdnURLs) == (["https://audio-ak.spotifycdn.com/a", "https://audio-ak.spotifycdn.com/b"]),
                "cdn urls decode in order")
            #expect((decodedCDN.fileID) == (Data([0x01, 0x02, 0x03, 0x04])), "file id decodes")

            var restricted = ProtobufWriter()
            restricted.varint(field: 1, 3)
            let decodedRestricted = StorageResolveResponse(protobuf: restricted.data)
            #expect((decodedRestricted.result) == (.restricted), "restricted result decodes")
            #expect((decodedRestricted.cdnURLs) == ([]), "restricted has no cdn urls")
            #expect((decodedRestricted.fileID) == nil, "restricted has no file id")

            var unknownResult = ProtobufWriter()
            unknownResult.varint(field: 1, 7)
            #expect(
                (StorageResolveResponse(protobuf: unknownResult.data).result) == nil,
                "unrecognised result raw value is nil, not a crash")

            var overflowingResult = ProtobufWriter()
            overflowingResult.varint(field: 1, UInt64.max)
            #expect(
                (StorageResolveResponse(protobuf: overflowingResult.data).result) == nil,
                "a result value too large for Int is nil, not a crash")
        }

        do {
            // The four query conventions are tried on every URL regardless of host — librespot's
            // `MaybeExpiringUrls` does not switch on the CDN either.
            #expect((CDNURLExpiry.margin) == (300), "margin is 5 minutes")

            let verify = URL(string: "https://audio-ak.spotifycdn.com/audio/x?verify=1700000000-abcdef")!
            #expect(
                (CDNURLExpiry.expiry(of: verify)) == (Date(timeIntervalSince1970: 1_700_000_000)), "verify= before '-'")

            let token = URL(string: "https://audio-gm-off.akamaized.net/audio/x?__token__=st=0~exp=1700000002~hmac=ab")!
            #expect(
                (CDNURLExpiry.expiry(of: token)) == (Date(timeIntervalSince1970: 1_700_000_002)),
                "__token__ exp= up to '~'"
            )

            let expires = URL(string: "https://audio-ak.spotifycdn.com/audio/x?Expires=1700000001~abcdef")!
            #expect(
                (CDNURLExpiry.expiry(of: expires)) == (Date(timeIntervalSince1970: 1_700_000_001)),
                "Expires= before '~'")

            let firstKeyFallback = URL(string: "https://audio-fa.scdn.co/audio/x?1700000003_abcdef=1")!
            #expect(
                (CDNURLExpiry.expiry(of: firstKeyFallback)) == (Date(timeIntervalSince1970: 1_700_000_003)),
                "fallback: first query key before '_'")

            let verifyOnUnrelatedHost = URL(string: "https://example.com/audio/x?verify=1700000000-abcdef")!
            #expect(
                (CDNURLExpiry.expiry(of: verifyOnUnrelatedHost)) == (Date(timeIntervalSince1970: 1_700_000_000)),
                "verify= is tried regardless of host")

            let precedence = URL(
                string:
                    "https://audio-ak.spotifycdn.com/x?verify=1700000000-a&__token__=exp=1600000000&Expires=1500000000~a"
            )!
            #expect(
                (CDNURLExpiry.expiry(of: precedence)) == (Date(timeIntervalSince1970: 1_700_000_000)),
                "verify= wins over __token__ and Expires= when more than one is present")

            let noVerifyPrecedence = URL(
                string: "https://audio-ak.spotifycdn.com/x?__token__=exp=1600000000&Expires=1500000000~a"
            )!
            #expect(
                (CDNURLExpiry.expiry(of: noVerifyPrecedence)) == (Date(timeIntervalSince1970: 1_600_000_000)),
                "__token__ wins over Expires= when both are present")

            let unparseableQuery = URL(string: "https://example.com/audio/x?foo=1700000000-abcdef")!
            #expect(
                (CDNURLExpiry.expiry(of: unparseableQuery)) == nil,
                "a query with none of the four conventions is unparseable")

            let missingQueryItem = URL(string: "https://audio-ak.spotifycdn.com/audio/x")!
            #expect((CDNURLExpiry.expiry(of: missingQueryItem)) == nil, "missing query item is unparseable")

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let atMargin = "https://audio-ak.spotifycdn.com/x?verify=1700000300-a"  // now + margin exactly
            let justPastMargin = "https://audio-ak.spotifycdn.com/x?verify=1700000301-a"  // now + margin + 1s
            let expired = "https://audio-ak.spotifycdn.com/x?verify=1699999999-a"  // already expired
            let unparseable = "https://example.com/x"

            let usable = CDNURLExpiry.usableURLs([atMargin, justPastMargin, expired, unparseable], now: now)
            #expect(
                (usable.map(\.absoluteString)) == ([justPastMargin, unparseable]),
                "usableURLs drops at-margin and expired, keeps just-past-margin and unparseable")

            // Exactly now plus the safety margin.
            let tokenAtMargin = "https://audio-ak.spotifycdn.com/x?__token__=exp=1700000300~hmac=a"
            #expect(
                (CDNURLExpiry.usableURLs([tokenAtMargin], now: now)) == ([]),
                "usableURLs drops a __token__ url that is inside the margin")
        }
    }
}
