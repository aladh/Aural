//
//  StorageResolveChecks.swift
//  Spotty
//

import SpottyDomain
import Foundation

func runStorageResolveChecks(_ check: CheckRunner) {
    check.suite("StorageResolveResponse protobuf decoding") {
        var cdn = ProtobufWriter()
        cdn.varint(field: 1, 0)
        cdn.string(field: 2, "https://audio-ak.spotifycdn.com/a")
        cdn.string(field: 2, "https://audio-ak.spotifycdn.com/b")
        cdn.bytes(field: 4, Data([0x01, 0x02, 0x03, 0x04]))
        cdn.varint(field: 99, 42)  // unknown field: must be skipped, not misread as a known one.

        let decodedCDN = StorageResolveResponse(protobuf: cdn.data)
        check.equal("cdn result decodes", decodedCDN.result, .cdn)
        check.equal(
            "cdn urls decode in order",
            decodedCDN.cdnURLs,
            ["https://audio-ak.spotifycdn.com/a", "https://audio-ak.spotifycdn.com/b"]
        )
        check.equal("file id decodes", decodedCDN.fileID, Data([0x01, 0x02, 0x03, 0x04]))

        var restricted = ProtobufWriter()
        restricted.varint(field: 1, 3)
        let decodedRestricted = StorageResolveResponse(protobuf: restricted.data)
        check.equal("restricted result decodes", decodedRestricted.result, .restricted)
        check.equal("restricted has no cdn urls", decodedRestricted.cdnURLs, [])
        check.nil_("restricted has no file id", decodedRestricted.fileID)

        var unknownResult = ProtobufWriter()
        unknownResult.varint(field: 1, 7)
        check.nil_(
            "unrecognised result raw value is nil, not a crash",
            StorageResolveResponse(protobuf: unknownResult.data).result
        )

        var overflowingResult = ProtobufWriter()
        overflowingResult.varint(field: 1, UInt64.max)
        check.nil_(
            "a result value too large for Int is nil, not a crash",
            StorageResolveResponse(protobuf: overflowingResult.data).result
        )
    }

    check.suite("CDNURLExpiry parsing") {
        // The four query conventions are tried on every URL regardless of host — librespot's
        // `MaybeExpiringUrls` does not switch on the CDN either.
        check.equal("margin is 5 minutes", CDNURLExpiry.margin, 300)

        let verify = URL(string: "https://audio-ak.spotifycdn.com/audio/x?verify=1700000000-abcdef")!
        check.equal(
            "verify= before '-'",
            CDNURLExpiry.expiry(of: verify),
            Date(timeIntervalSince1970: 1_700_000_000)
        )

        let token = URL(string: "https://audio-gm-off.akamaized.net/audio/x?__token__=st=0~exp=1700000002~hmac=ab")!
        check.equal(
            "__token__ exp= up to '~'",
            CDNURLExpiry.expiry(of: token),
            Date(timeIntervalSince1970: 1_700_000_002)
        )

        let expires = URL(string: "https://audio-ak.spotifycdn.com/audio/x?Expires=1700000001~abcdef")!
        check.equal(
            "Expires= before '~'",
            CDNURLExpiry.expiry(of: expires),
            Date(timeIntervalSince1970: 1_700_000_001)
        )

        let firstKeyFallback = URL(string: "https://audio-fa.scdn.co/audio/x?1700000003_abcdef=1")!
        check.equal(
            "fallback: first query key before '_'",
            CDNURLExpiry.expiry(of: firstKeyFallback),
            Date(timeIntervalSince1970: 1_700_000_003)
        )

        let verifyOnUnrelatedHost = URL(string: "https://example.com/audio/x?verify=1700000000-abcdef")!
        check.equal(
            "verify= is tried regardless of host",
            CDNURLExpiry.expiry(of: verifyOnUnrelatedHost),
            Date(timeIntervalSince1970: 1_700_000_000)
        )

        let precedence = URL(
            string:
                "https://audio-ak.spotifycdn.com/x?verify=1700000000-a&__token__=exp=1600000000&Expires=1500000000~a"
        )!
        check.equal(
            "verify= wins over __token__ and Expires= when more than one is present",
            CDNURLExpiry.expiry(of: precedence),
            Date(timeIntervalSince1970: 1_700_000_000)
        )

        let noVerifyPrecedence = URL(
            string: "https://audio-ak.spotifycdn.com/x?__token__=exp=1600000000&Expires=1500000000~a"
        )!
        check.equal(
            "__token__ wins over Expires= when both are present",
            CDNURLExpiry.expiry(of: noVerifyPrecedence),
            Date(timeIntervalSince1970: 1_600_000_000)
        )

        let unparseableQuery = URL(string: "https://example.com/audio/x?foo=1700000000-abcdef")!
        check.nil_(
            "a query with none of the four conventions is unparseable",
            CDNURLExpiry.expiry(of: unparseableQuery)
        )

        let missingQueryItem = URL(string: "https://audio-ak.spotifycdn.com/audio/x")!
        check.nil_("missing query item is unparseable", CDNURLExpiry.expiry(of: missingQueryItem))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let atMargin = "https://audio-ak.spotifycdn.com/x?verify=1700000300-a"  // now + margin exactly
        let justPastMargin = "https://audio-ak.spotifycdn.com/x?verify=1700000301-a"  // now + margin + 1s
        let expired = "https://audio-ak.spotifycdn.com/x?verify=1699999999-a"  // already expired
        let unparseable = "https://example.com/x"

        let usable = CDNURLExpiry.usableURLs([atMargin, justPastMargin, expired, unparseable], now: now)
        check.equal(
            "usableURLs drops at-margin and expired, keeps just-past-margin and unparseable",
            usable.map(\.absoluteString),
            [justPastMargin, unparseable]
        )

        let tokenAtMargin = "https://audio-ak.spotifycdn.com/x?__token__=exp=1700000300~hmac=a"  // now + margin exactly
        check.equal(
            "usableURLs drops a __token__ url that is inside the margin",
            CDNURLExpiry.usableURLs([tokenAtMargin], now: now),
            []
        )
    }
}
