//
//  StorageResolveChecks.swift
//  Aural
//

import AuralDomain
import Foundation

func runStorageResolveChecks(_ check: CheckRunner) {
    check.suite("StorageResolveResponse protobuf decoding") {
        var cdn = ProtobufWriter()
        cdn.varint(field: 1, 0)
        cdn.string(field: 2, "https://audio-ak.spotifycdn.com/a")
        cdn.string(field: 2, "https://audio-ak.spotifycdn.com/b")
        cdn.bytes(field: 4, Data([0x01, 0x02, 0x03, 0x04]))
        cdn.varint(field: 99, 42)  // unknown field: must be skipped, not misread as a known one.

        if let decoded = StorageResolveResponse(protobuf: cdn.data) {
            check.equal("cdn result decodes", decoded.result, .cdn)
            check.equal(
                "cdn urls decode in order",
                decoded.cdnURLs,
                ["https://audio-ak.spotifycdn.com/a", "https://audio-ak.spotifycdn.com/b"]
            )
            check.equal("file id decodes", decoded.fileID, Data([0x01, 0x02, 0x03, 0x04]))
        } else {
            check.check("cdn response decodes", false)
        }

        var restricted = ProtobufWriter()
        restricted.varint(field: 1, 3)
        if let decoded = StorageResolveResponse(protobuf: restricted.data) {
            check.equal("restricted result decodes", decoded.result, .restricted)
            check.equal("restricted has no cdn urls", decoded.cdnURLs, [])
            check.nil_("restricted has no file id", decoded.fileID)
        } else {
            check.check("restricted response decodes", false)
        }

        var unknownResult = ProtobufWriter()
        unknownResult.varint(field: 1, 7)
        if let decoded = StorageResolveResponse(protobuf: unknownResult.data) {
            check.nil_("unrecognised result raw value is nil, not a crash", decoded.result)
        } else {
            check.check("response with unrecognised result still decodes", false)
        }
    }

    check.suite("CDNURLExpiry parsing") {
        check.equal("margin is 5 minutes", CDNURLExpiry.margin, 300)

        let spotifycdnVerify = URL(string: "https://audio-ak.spotifycdn.com/audio/x?verify=1700000000-abcdef")!
        check.equal(
            "spotifycdn.com verify= before '-'",
            CDNURLExpiry.expiry(of: spotifycdnVerify),
            Date(timeIntervalSince1970: 1_700_000_000)
        )

        let spotifycdnExpires = URL(string: "https://audio-ak.spotifycdn.com/audio/x?Expires=1700000001~abcdef")!
        check.equal(
            "spotifycdn.com Expires= before '~'",
            CDNURLExpiry.expiry(of: spotifycdnExpires),
            Date(timeIntervalSince1970: 1_700_000_001)
        )

        let akamaized = URL(string: "https://audio-gm-off.akamaized.net/audio/x?__token__=st=0~exp=1700000002~hmac=ab")!
        check.equal(
            "akamaized.net __token__ exp= up to '~'",
            CDNURLExpiry.expiry(of: akamaized),
            Date(timeIntervalSince1970: 1_700_000_002)
        )

        let scdn = URL(string: "https://audio-fa.scdn.co/audio/x?1700000003_abcdef=1")!
        check.equal(
            "scdn.co first query key before '_'",
            CDNURLExpiry.expiry(of: scdn),
            Date(timeIntervalSince1970: 1_700_000_003)
        )

        let unrecognisedHost = URL(string: "https://example.com/audio/x?verify=1700000000-abcdef")!
        check.nil_(
            "unrecognised host is unparseable (treated as never expiring)",
            CDNURLExpiry.expiry(of: unrecognisedHost)
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
    }
}
