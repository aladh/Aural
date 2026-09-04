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
    /// Never fails: a message with none of these fields simply decodes to all-nil/empty.
    public init(protobuf data: Data) {
        if let raw = ProtobufReader.firstVarint(field: 1, in: data), let raw = Int(exactly: raw) {
            result = Result(rawValue: raw)
        } else {
            result = nil
        }

        cdnURLs = ProtobufReader.fields(in: data).compactMap { field -> String? in
            guard field.number == 2, let payload = field.bytesPayload else { return nil }
            return String(data: payload, encoding: .utf8)
        }

        fileID = ProtobufReader.firstBytes(field: 4, in: data)
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

    /// The Unix-seconds expiry encoded in `url`'s query string, or `nil` if it cannot be parsed.
    ///
    /// Mirrors librespot's `MaybeExpiringUrls`, which tries the same four query conventions on
    /// every URL regardless of which CDN host it names, in this order: `verify=<digits>-...`,
    /// `__token__=...exp=<digits>...`, `Expires=<digits>~...`, and finally (as a catch-all)
    /// whichever query item comes first, if its key starts with `<digits>_`.
    public static func expiry(of url: URL) -> Date? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if let verify = value("verify"), let seconds = leadingInteger(verify, before: "-") {
            return Date(timeIntervalSince1970: seconds)
        }
        if let seconds = tokenExpiry(value("__token__")) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let expires = value("Expires"), let seconds = leadingInteger(expires, before: "~") {
            return Date(timeIntervalSince1970: seconds)
        }
        if let firstKey = items.first?.name, let seconds = leadingInteger(firstKey, before: "_") {
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

    /// The `exp=<digits>` expiry seconds inside a `__token__` query value, as used by both
    /// Akamai's and Spotify's own CDN token format. `nil` if `token` is nil or has no `exp=`.
    private static func tokenExpiry(_ token: String?) -> TimeInterval? {
        guard let token, let expRange = token.range(of: "exp=") else { return nil }
        let afterExp = token[expRange.upperBound...]
        let digits = afterExp.prefix { $0.isNumber }
        return TimeInterval(digits)
    }
}
