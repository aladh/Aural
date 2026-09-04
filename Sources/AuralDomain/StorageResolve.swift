//
//  StorageResolve.swift
//  Aural
//
//  Decodes Spotify's storage-resolve response (which CDN URLs, if any, serve a file) and
//  replicates librespot's ad hoc CDN-URL expiry sniffing so Spotty knows when to re-resolve.
//

import Foundation

/// Decoded `StorageResolveResponse` protobuf: whether a file is served from a CDN, storage, or
/// is restricted in the current market, plus the CDN URLs and file ID when present.
public struct StorageResolveResponse: Sendable, Equatable {
    public enum Result: Int, Sendable {
        case cdn = 0
        case storage = 1
        case restricted = 3
    }

    public let result: Result?
    public let cdnURLs: [String]
    public let fileID: Data?

    public init(result: Result?, cdnURLs: [String], fileID: Data?) {
        self.result = result
        self.cdnURLs = cdnURLs
        self.fileID = fileID
    }

    /// Decodes field 1 (varint result), repeated field 2 (CDN URL strings), and field 4
    /// (file ID bytes). Unknown fields are skipped, matching `ProtobufReader`'s general policy.
    public init?(protobuf data: Data) {
        let fields = ProtobufReader.fields(in: data)

        let result = fields.lazy.compactMap { field -> Result? in
            guard field.number == 1, let raw = field.varintValue else { return nil }
            return Result(rawValue: Int(raw))
        }.first

        let cdnURLs = fields.compactMap { field -> String? in
            guard field.number == 2, let payload = field.bytesPayload else { return nil }
            return String(data: payload, encoding: .utf8)
        }

        let fileID = fields.lazy.compactMap { field -> Data? in
            guard field.number == 4 else { return nil }
            return field.bytesPayload
        }.first

        self.result = result
        self.cdnURLs = cdnURLs
        self.fileID = fileID
    }
}

/// Reproduces librespot's `MaybeExpiringUrls` heuristics for reading an expiry timestamp out of
/// a Spotify CDN URL's query string. Spotify does not document a single expiry query parameter;
/// each CDN family encodes it differently, and a URL whose expiry cannot be parsed is treated as
/// never expiring, same as librespot.
public enum CDNURLExpiry {
    /// Seconds of slack subtracted from "now" before comparing against a URL's expiry, so a URL
    /// that is about to expire is not handed to a request that will still be in flight then.
    public static let margin: TimeInterval = 300

    /// The Unix-seconds expiry encoded in `url`'s query string, or `nil` if it cannot be parsed
    /// (host not recognized, expected query item missing, or its value not an integer prefix).
    public static func expiry(of url: URL) -> Date? {
        guard let host = url.host else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if host.contains("spotifycdn.com") {
            if let verify = value("verify"), let seconds = leadingInteger(verify, before: "-") {
                return Date(timeIntervalSince1970: seconds)
            }
            if let expires = value("Expires"), let seconds = leadingInteger(expires, before: "~") {
                return Date(timeIntervalSince1970: seconds)
            }
            return nil
        }

        if host.contains("akamaized.net") {
            guard let token = value("__token__"),
                let expRange = token.range(of: "exp=")
            else { return nil }
            let afterExp = token[expRange.upperBound...]
            let digits = afterExp.prefix { $0.isNumber }
            guard let seconds = TimeInterval(digits) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }

        if host.contains("scdn.co") {
            guard let firstKey = items.first?.name,
                let seconds = leadingInteger(firstKey, before: "_")
            else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }

        return nil
    }

    /// Keeps only the URLs that either have no parseable expiry or expire after `now + margin`,
    /// preserving input order.
    public static func usableURLs(_ urls: [String], now: Date) -> [URL] {
        urls.compactMap(URL.init(string:)).filter { url in
            guard let expiry = expiry(of: url) else { return true }
            return expiry > now.addingTimeInterval(margin)
        }
    }

    /// The integer formed by the digits at the start of `value`, up to (but not including) the
    /// first occurrence of `separator`. `nil` if there is no leading integer.
    private static func leadingInteger(_ value: String, before separator: Character) -> TimeInterval? {
        let head = value[value.startIndex..<(value.firstIndex(of: separator) ?? value.endIndex)]
        let digits = head.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return TimeInterval(digits)
    }
}
