//
//  RangedAudioFetcher.swift
//  Aural
//
//  Fetches a Spotify CDN audio file in byte ranges and keeps the downloaded pieces in a sparse
//  store, so playback can start from the first chunk and read ahead of the play position
//  without downloading the whole file up front.
//
//  `read`/`prefetch` validate their inputs (negative or overflowing ranges, and reads past end
//  of file) before touching the downloaded-range store, clamping a read that runs past the last
//  byte to the shorter slice instead of trapping. `ensureDownloaded` only fetches the sub-ranges
//  of a request that are actually missing from `segments`, each widened to at least
//  `initialChunk` bytes but never past the file end or into bytes already stored just after the
//  gap; `store` coalesces the results with any adjacent or overlapping segments so the store
//  never accumulates redundant pieces. `fetchAndStore` copes with a CDN that returns less than
//  requested in a single 206 (looping for the remainder, bounded by the response actually making
//  progress) and with one that ignores the `Range` header entirely and returns 200 (accepted
//  only when the request started at byte 0, since that is the only case a full-body response
//  can satisfy). Response headers are matched case-insensitively throughout.
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

public enum RangedAudioFetcherError: Error, Sendable, Equatable {
    case forbidden
    case unexpectedStatus(Int)
    case unparseableContentRange
    /// A caller passed a negative offset/length, an offset+length that overflows `Int`, or (for
    /// `read`) an offset at or past the file's total length.
    case invalidRange
    /// `read` fetched successfully but the downloaded-range store still had fewer bytes than
    /// requested (after clamping to the file's end) — a bug in the store's bookkeeping, since
    /// `ensureDownloaded` is supposed to guarantee the requested span is fully covered.
    case shortRead
}

/// Fetches one CDN file's bytes on demand, in ranges, keeping what has been downloaded so a
/// repeated read never re-fetches bytes it already has.
///
/// Mirrors librespot's ranged-fetch defaults: a 64 KiB minimum download per request (fetching
/// less than that for a single missing byte is wasteful) and roughly 5 seconds of read-ahead
/// during playback (`readAheadDuration`, in bytes-per-second terms left to the caller — this
/// type only exposes `prefetch(from:upTo:)` for the caller to drive). It does not implement
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

    /// The bytes at `offset..<offset+length`, fetching whatever is missing first. A request that
    /// runs past the end of the file is clamped to the bytes that exist, rather than trapping;
    /// an `offset` at or past the end of the file throws `.invalidRange`. Throws `.shortRead` if,
    /// after fetching, the store still can't produce the full (clamped) span requested.
    public func read(offset: Int, length: Int) async throws -> Data {
        guard offset >= 0, length >= 0 else { throw RangedAudioFetcherError.invalidRange }
        let (requestedEnd, overflowed) = offset.addingReportingOverflow(length)
        guard !overflowed else { throw RangedAudioFetcherError.invalidRange }
        guard length > 0 else { return Data() }

        if totalLength == nil { try await open() }
        guard let totalLength else { throw RangedAudioFetcherError.invalidRange }
        guard offset < totalLength else { throw RangedAudioFetcherError.invalidRange }

        let clampedLength = min(requestedEnd, totalLength) - offset
        try await ensureDownloaded(offset: offset, length: clampedLength)
        let result = sliced(offset: offset, length: clampedLength)
        guard result.count == clampedLength else { throw RangedAudioFetcherError.shortRead }
        return result
    }

    /// Fetches ahead of the play position: every missing byte in `offset...end`, without
    /// returning anything. Never fills from byte 0 unless `offset` is 0 — callers drive the
    /// read-ahead window explicitly, since the play position (not the file start) is what
    /// determines what is worth prefetching. Used to keep playback from stalling on a
    /// synchronous fetch.
    public func prefetch(from offset: Int, upTo end: Int) async throws {
        guard offset >= 0, end >= offset else { throw RangedAudioFetcherError.invalidRange }
        if totalLength == nil { try await open() }
        guard let totalLength, totalLength > 0 else { return }

        let clampedEnd = min(end, totalLength - 1)
        guard clampedEnd >= offset else { return }
        let length = clampedEnd - offset + 1
        guard !isFullyDownloaded(offset: offset, length: length) else { return }
        try await ensureDownloaded(offset: offset, length: length)
    }

    // MARK: - Downloaded-range bookkeeping

    /// Fetches every sub-range of `offset..<offset+length` not already in `segments`, each
    /// widened to at least `initialChunk` bytes (clamped to the file end and to the next stored
    /// segment, so a widened fetch never re-requests bytes already on hand).
    private func ensureDownloaded(offset: Int, length: Int) async throws {
        guard let totalLength else {
            try await open()
            try await ensureDownloaded(offset: offset, length: length)
            return
        }
        let fileEnd = totalLength - 1
        for gap in missingRanges(offset: offset, length: length) {
            try await fetchAndStore(widen(gap, fileEnd: fileEnd))
        }
    }

    /// The sub-ranges of `offset..<offset+length` not covered by any stored segment, in order.
    private func missingRanges(offset: Int, length: Int) -> [Range<Int>] {
        guard length > 0 else { return [] }
        let end = offset + length
        var missing: [Range<Int>] = []
        var cursor = offset
        for segment in segments {
            let segmentStart = segment.offset
            let segmentEnd = segment.offset + segment.data.count
            guard segmentEnd > cursor else { continue }
            guard segmentStart < end else { break }
            if segmentStart > cursor {
                missing.append(cursor..<segmentStart)
            }
            cursor = max(cursor, segmentEnd)
            if cursor >= end { return missing }
        }
        if cursor < end {
            missing.append(cursor..<end)
        }
        return missing
    }

    /// Widens a missing `range` to at least `initialChunk` bytes, without extending past
    /// `fileEnd` or into whatever stored segment comes right after it.
    private func widen(_ range: Range<Int>, fileEnd: Int) -> ClosedRange<Int> {
        let start = range.lowerBound
        let desiredEnd = start + max(range.count, Self.initialChunk) - 1
        var end = min(desiredEnd, fileEnd)
        if let nextSegmentStart = segments.first(where: { $0.offset > start })?.offset {
            end = min(end, nextSegmentStart - 1)
        }
        return start...max(end, start)
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

    /// Inserts `data` at `offset`, coalescing it with any segment it overlaps or touches so
    /// `segments` never holds two pieces that could be one. When segments overlap, the
    /// already-stored bytes win for the overlapping region; only new bytes past that are kept.
    private func store(offset: Int, data: Data) {
        guard !data.isEmpty else { return }
        var all = segments
        all.append((offset, data))
        all.sort { $0.offset < $1.offset }

        var merged: [(offset: Int, data: Data)] = []
        for segment in all {
            guard let last = merged.last else {
                merged.append(segment)
                continue
            }
            let lastEnd = last.offset + last.data.count
            guard segment.offset <= lastEnd else {
                merged.append(segment)
                continue
            }
            let segmentEnd = segment.offset + segment.data.count
            guard segmentEnd > lastEnd else { continue }  // fully contained in `last`: drop it.
            var extended = last
            let newBytesStart = lastEnd - segment.offset
            extended.data.append(segment.data[segment.data.startIndex + newBytesStart...])
            merged[merged.count - 1] = extended
        }
        segments = merged
    }

    // MARK: - Transport

    /// Fetches `range`, retrying on 429 and looping to cover the rest of `range` if the CDN
    /// returns less than requested in one 206 response. Returns the file's total length.
    @discardableResult
    private func fetchAndStore(_ range: ClosedRange<Int>) async throws -> Int {
        var attempt = 0
        var pending = range
        while true {
            let response = try await transport.fetch(url, range: pending)
            switch response.statusCode {
            case 206:
                let (a, b, total) = try Self.parseContentRange(response.headers)
                guard response.body.count == b - a + 1 else {
                    throw RangedAudioFetcherError.unparseableContentRange
                }
                if totalLength == nil {
                    totalLength = total
                }
                store(offset: a, data: response.body)
                attempt = 0

                if b < pending.upperBound, b < total - 1 {
                    guard !response.body.isEmpty else { throw RangedAudioFetcherError.unexpectedStatus(206) }
                    pending = (b + 1)...pending.upperBound
                    continue
                }
                return total
            case 200:
                // The server ignored `Range` and sent the whole body. Only a request that
                // wanted the file from the start can be satisfied by that.
                guard range.lowerBound == 0 else { throw RangedAudioFetcherError.unexpectedStatus(200) }
                totalLength = response.body.count
                store(offset: 0, data: response.body)
                return response.body.count
            case 429:
                attempt += 1
                guard attempt <= Self.maxRetries else { throw RangedAudioFetcherError.unexpectedStatus(429) }
                try await sleep(Self.retryDelay(headers: response.headers))
            case 403:
                throw RangedAudioFetcherError.forbidden
            default:
                throw RangedAudioFetcherError.unexpectedStatus(response.statusCode)
            }
        }
    }

    /// Parses `Content-Range: bytes a-b/total`.
    private static func parseContentRange(_ headers: [String: String]) throws -> (a: Int, b: Int, total: Int) {
        guard let raw = header(headers, "Content-Range") else {
            throw RangedAudioFetcherError.unparseableContentRange
        }
        let prefix = "bytes "
        guard raw.hasPrefix(prefix) else { throw RangedAudioFetcherError.unparseableContentRange }
        let rest = raw.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { throw RangedAudioFetcherError.unparseableContentRange }
        let rangePart = rest[rest.startIndex..<slash]
        guard let dash = rangePart.firstIndex(of: "-") else { throw RangedAudioFetcherError.unparseableContentRange }
        guard let a = Int(rangePart[rangePart.startIndex..<dash]),
            let b = Int(rangePart[rangePart.index(after: dash)...]),
            let total = Int(rest[rest.index(after: slash)...])
        else { throw RangedAudioFetcherError.unparseableContentRange }
        return (a, b, total)
    }

    /// `Retry-After`, as delay-seconds first, else an HTTP-date (RFC 1123), else a 1-second
    /// fallback. A date already in the past yields no delay; a future date is capped at 30s.
    private static func retryDelay(headers: [String: String]) -> Duration {
        guard let value = header(headers, "Retry-After") else { return .seconds(1) }
        if let seconds = Double(value) {
            return .seconds(seconds)
        }
        if let date = retryAfterDateFormatter.date(from: value) {
            let interval = date.timeIntervalSinceNow
            return .seconds(max(0, min(interval, 30)))
        }
        return .seconds(1)
    }

    private static let retryAfterDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Looks up `name` in `headers` case-insensitively — HTTP header names are case-insensitive,
    /// and transports (or checks scripting one) don't all normalize them the same way.
    private static func header(_ headers: [String: String], _ name: String) -> String? {
        if let value = headers[name] { return value }
        let lowerName = name.lowercased()
        return headers.first { $0.key.lowercased() == lowerName }?.value
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
        // `value(forHTTPHeaderField:)` itself matches case-insensitively; the fetcher's own
        // lookup (`RangedAudioFetcher.header`) does too, so the canonical casing here is only
        // for readability, not correctness.
        var headers: [String: String] = [:]
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
            headers["Content-Range"] = contentRange
        }
        if let retryAfter = http.value(forHTTPHeaderField: "Retry-After") {
            headers["Retry-After"] = retryAfter
        }
        return RangedHTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
    }
}
