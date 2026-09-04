//
//  RangedAudioFetcher.swift
//  Aural
//
//  Fetches a Spotify CDN audio file in byte ranges and keeps the downloaded pieces in a sparse
//  store, so playback can start from the first chunk and read ahead of the play position
//  without downloading the whole file up front.
//

import Foundation

/// One HTTP range response, as far as `RangedAudioFetcher` needs it.
public struct RangedHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// The narrow HTTP seam `RangedAudioFetcher` fetches through, so checks can script CDN
/// responses without a real network.
public protocol RangedHTTPTransport: Sendable {
    func fetch(_ url: URL, range: ClosedRange<Int>) async throws -> RangedHTTPResponse
}

public enum RangedAudioFetcherError: Error, Sendable {
    case forbidden
    case unexpectedStatus(Int)
    case unparseableContentRange
}

/// Fetches one CDN file's bytes on demand, in ranges, keeping what has been downloaded so a
/// repeated read never re-fetches bytes it already has.
///
/// Mirrors librespot's ranged-fetch defaults: a 64 KiB minimum download per request (fetching
/// less than that for a single missing byte is wasteful) and roughly 5 seconds of read-ahead
/// during playback (`readAheadDuration`, in bytes-per-second terms left to the caller — this
/// type only exposes `prefetch(upTo:)` for the caller to drive). It does not implement
/// librespot's adaptive ping-based read-ahead tuning; that is a later refinement, not a
/// correctness requirement for a first landing slice.
public actor RangedAudioFetcher {
    /// Minimum bytes requested per fetch, matching librespot's `MINIMUM_DOWNLOAD_SIZE`.
    public static let initialChunk = 64 * 1024

    /// Maximum HTTP 429 retries before giving up and surfacing the error.
    private static let maxRetries = 3

    private let url: URL
    private let transport: RangedHTTPTransport
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Downloaded byte ranges, sorted and non-overlapping: (offset, bytes at that offset).
    private var segments: [(offset: Int, data: Data)] = []
    private var totalLength: Int?

    public init(
        url: URL,
        transport: RangedHTTPTransport,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.url = url
        self.transport = transport
        self.sleep = sleep
    }

    /// The file's total length, once known from a `Content-Range` response.
    public var length: Int? { totalLength }

    /// Fetches the first chunk and learns the file's total length from `Content-Range`.
    /// Must be called (directly, or implicitly via `read`/`prefetch`) before the length is known.
    @discardableResult
    public func open() async throws -> Int {
        let end = min(Self.initialChunk - 1, (totalLength ?? Int.max) - 1)
        let range = try await fetchAndStore(0...max(end, 0))
        return range
    }

    /// The bytes at `offset..<offset+length`, fetching whatever is missing first.
    public func read(offset: Int, length: Int) async throws -> Data {
        try await ensureDownloaded(offset: offset, length: length)
        return sliced(offset: offset, length: length)
    }

    /// Fetches ahead of the play position, up to `offset`, without returning anything. Callers
    /// use this to keep playback from stalling on a synchronous fetch.
    public func prefetch(upTo offset: Int) async throws {
        guard let totalLength else {
            try await open()
            try await prefetch(upTo: offset)
            return
        }
        let end = min(offset, totalLength - 1)
        guard end >= 0, !isFullyDownloaded(offset: 0, length: end + 1) else { return }
        try await ensureDownloaded(offset: 0, length: end + 1)
    }

    // MARK: - Downloaded-range bookkeeping

    private func ensureDownloaded(offset: Int, length: Int) async throws {
        guard totalLength != nil else {
            try await open()
            try await ensureDownloaded(offset: offset, length: length)
            return
        }
        guard !isFullyDownloaded(offset: offset, length: length) else { return }

        let fileEnd = (totalLength ?? offset + length) - 1
        let minimumEnd = offset + max(length, Self.initialChunk) - 1
        let end = min(minimumEnd, fileEnd)
        guard end >= offset else { return }
        try await fetchAndStore(offset...end)
    }

    private func isFullyDownloaded(offset: Int, length: Int) -> Bool {
        guard length > 0 else { return true }
        var cursor = offset
        let end = offset + length
        for segment in segments where segment.offset <= cursor {
            let segmentEnd = segment.offset + segment.data.count
            guard segmentEnd > cursor else { continue }
            cursor = segmentEnd
            if cursor >= end { return true }
        }
        return cursor >= end
    }

    private func sliced(offset: Int, length: Int) -> Data {
        var result = Data(capacity: length)
        var cursor = offset
        let end = offset + length
        for segment in segments where segment.offset <= cursor {
            let segmentEnd = segment.offset + segment.data.count
            guard segmentEnd > cursor else { continue }
            let sliceStart = cursor - segment.offset
            let sliceEnd = min(segmentEnd, end) - segment.offset
            result.append(segment.data[segment.data.startIndex + sliceStart..<segment.data.startIndex + sliceEnd])
            cursor = segment.offset + sliceEnd
            if cursor >= end { break }
        }
        return result
    }

    private func store(offset: Int, data: Data) {
        segments.append((offset, data))
        segments.sort { $0.offset < $1.offset }
    }

    // MARK: - Transport

    @discardableResult
    private func fetchAndStore(_ range: ClosedRange<Int>) async throws -> Int {
        var attempt = 0
        while true {
            let response = try await transport.fetch(url, range: range)
            switch response.statusCode {
            case 206:
                if totalLength == nil {
                    totalLength = try Self.parseTotalLength(response.headers)
                }
                store(offset: range.lowerBound, data: response.body)
                return totalLength ?? (range.lowerBound + response.body.count)
            case 429:
                attempt += 1
                guard attempt <= Self.maxRetries else { throw RangedAudioFetcherError.unexpectedStatus(429) }
                let delay = response.headers["Retry-After"].flatMap { Double($0) } ?? 1
                try await sleep(.seconds(delay))
            case 403:
                throw RangedAudioFetcherError.forbidden
            default:
                throw RangedAudioFetcherError.unexpectedStatus(response.statusCode)
            }
        }
    }

    /// Parses `Content-Range: bytes a-b/total` for `total`.
    private static func parseTotalLength(_ headers: [String: String]) throws -> Int {
        guard let contentRange = headers["Content-Range"],
            let slash = contentRange.firstIndex(of: "/")
        else { throw RangedAudioFetcherError.unparseableContentRange }
        let totalPart = contentRange[contentRange.index(after: slash)...]
        guard let total = Int(totalPart) else { throw RangedAudioFetcherError.unparseableContentRange }
        return total
    }
}

/// `URLSession`-backed `RangedHTTPTransport`. Sends only the `Range` header — no auth headers —
/// because Spotify's CDN URLs are pre-signed and do not accept (or need) account credentials.
public struct URLSessionRangedTransport: RangedHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ url: URL, range: ClosedRange<Int>) async throws -> RangedHTTPResponse {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")

        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RangedAudioFetcherError.unexpectedStatus(-1)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return RangedHTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
    }
}
