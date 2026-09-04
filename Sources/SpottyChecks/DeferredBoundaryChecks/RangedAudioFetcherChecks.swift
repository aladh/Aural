import Foundation
@testable import SpottyCore

@MainActor
func runRangedAudioFetcherChecks(_ check: CheckRunner) async {
    let url = URL(string: "https://audio-ak.spotifycdn.com/audio/fixture")!

    await check.suite("RangedAudioFetcher: open, read, minimum-chunk widening, EOF clamping") {
        let openTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-39/40"], body: bytes(0..<40))
        ])
        let opened = try? await RangedAudioFetcher(url: url, transport: openTransport).open()
        check.equal("open() returns the total length parsed from Content-Range", opened, 40)
        check.equal("open() fetches exactly one range", openTransport.requestedRanges.count, 1)
        check.equal("open() requests from byte 0", openTransport.requestedRanges.first?.lowerBound, 0)

        let readWithinTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-39/40"], body: bytes(0..<40))
        ])
        let readWithinFetcher = RangedAudioFetcher(url: url, transport: readWithinTransport)
        _ = try? await readWithinFetcher.open()
        let withinRead = try? await readWithinFetcher.read(offset: 2, length: 4)
        check.equal("read() inside the downloaded range returns the stored bytes", withinRead, bytes(2..<6))
        check.equal(
            "read() inside the downloaded range performs no extra fetch",
            readWithinTransport.requestedRanges.count,
            1
        )

        // A file much larger than the minimum chunk: open() fully satisfies its own 64 KiB
        // request in one response, so a later read well past it is a genuine gap, and — being
        // small — gets widened up to the minimum chunk size rather than fetched byte-for-byte.
        let minimumChunkTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-65535/200000"], body: bytes(0..<65536)),
            .response(
                status: 206,
                headers: ["Content-Range": "bytes 70000-135535/200000"],
                body: bytes(70_000..<135_536)
            ),
        ])
        let minimumChunkFetcher = RangedAudioFetcher(url: url, transport: minimumChunkTransport)
        _ = try? await minimumChunkFetcher.open()
        _ = try? await minimumChunkFetcher.read(offset: 70_000, length: 5)
        check.equal(
            "a missing read fetches at least the minimum chunk size",
            minimumChunkTransport.requestedRanges.last,
            70_000...135_535
        )

        // A read that runs past the end of a (larger) file is clamped to the bytes that exist,
        // both in what gets fetched and in what's returned — not widened past the last byte.
        let clampToEndTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-65535/70000"], body: bytes(0..<65536)),
            .response(status: 206, headers: ["Content-Range": "bytes 69990-69999/70000"], body: bytes(69_990..<70_000)),
        ])
        let clampToEndFetcher = RangedAudioFetcher(url: url, transport: clampToEndTransport)
        _ = try? await clampToEndFetcher.open()
        let clampedRead = try? await clampToEndFetcher.read(offset: 69_990, length: 20)
        check.equal(
            "a missing read near the end clamps the fetch to the file's last byte, not past it",
            clampToEndTransport.requestedRanges.last,
            69_990...69_999
        )
        check.equal(
            "a read past end of file returns the shorter slice that exists, not a trap",
            clampedRead,
            bytes(69_990..<70_000)
        )

        let retrySleeper = RecordingDurationSleeper()
        let retryTransport = ScriptedRangedTransport(steps: [
            .response(status: 429, headers: ["Retry-After": "1"], body: Data()),
            .response(status: 206, headers: ["Content-Range": "bytes 0-39/40"], body: bytes(0..<40)),
        ])
        let retryFetcher = RangedAudioFetcher(url: url, transport: retryTransport, sleep: retrySleeper.sleep)
        let retried = try? await retryFetcher.open()
        check.equal("a 429 with Retry-After retries and eventually succeeds", retried, 40)
        check.equal("the retry honours the Retry-After delay", retrySleeper.delays, [.seconds(1)])

        let forbiddenTransport = ScriptedRangedTransport(steps: [.response(status: 403, headers: [:], body: Data())])
        do {
            _ = try await RangedAudioFetcher(url: url, transport: forbiddenTransport).open()
            check.check("403 throws forbidden", false)
        } catch RangedAudioFetcherError.forbidden {
            check.check("403 throws forbidden", true)
        } catch {
            check.check("403 throws forbidden, not \(error)", false)
        }

        // A 200 (server ignored `Range`) is only acceptable for a request that wanted the file
        // from byte 0 — one for a later gap can't be satisfied by a full-body response.
        let unexpectedTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-65535/70000"], body: bytes(0..<65536)),
            .response(status: 200, headers: [:], body: Data()),
        ])
        let unexpectedFetcher = RangedAudioFetcher(url: url, transport: unexpectedTransport)
        _ = try? await unexpectedFetcher.open()
        do {
            _ = try await unexpectedFetcher.read(offset: 69_999, length: 1)
            check.check("a 200 for a non-zero-offset gap throws unexpectedStatus(200)", false)
        } catch RangedAudioFetcherError.unexpectedStatus(200) {
            check.check("a 200 for a non-zero-offset gap throws unexpectedStatus(200)", true)
        } catch {
            check.check("a 200 for a non-zero-offset gap throws unexpectedStatus(200), not \(error)", false)
        }
    }

    await check.suite("RangedAudioFetcher: invalid ranges") {
        await expectThrown(check, "negative offset", .invalidRange) {
            _ = try await RangedAudioFetcher(url: url, transport: ScriptedRangedTransport(steps: [])).read(
                offset: -1,
                length: 5
            )
        }
        await expectThrown(check, "negative length", .invalidRange) {
            _ = try await RangedAudioFetcher(url: url, transport: ScriptedRangedTransport(steps: [])).read(
                offset: 5,
                length: -1
            )
        }
        await expectThrown(check, "offset+length overflow", .invalidRange) {
            _ = try await RangedAudioFetcher(url: url, transport: ScriptedRangedTransport(steps: [])).read(
                offset: Int.max - 2,
                length: 10
            )
        }
        await expectThrown(check, "prefetch with a negative offset", .invalidRange) {
            try await RangedAudioFetcher(url: url, transport: ScriptedRangedTransport(steps: [])).prefetch(
                from: -1,
                upTo: 5
            )
        }
        await expectThrown(check, "prefetch with end before offset", .invalidRange) {
            try await RangedAudioFetcher(url: url, transport: ScriptedRangedTransport(steps: [])).prefetch(
                from: 10,
                upTo: 5
            )
        }

        let noFetchTransport = ScriptedRangedTransport(steps: [])
        let noFetchFetcher = RangedAudioFetcher(url: url, transport: noFetchTransport)
        let zeroLengthRead = try? await noFetchFetcher.read(offset: 0, length: 0)
        check.equal("a zero-length read returns empty data before any fetch", zeroLengthRead, Data())
        check.equal("validation happens before any fetch is attempted", noFetchTransport.requestedRanges.count, 0)

        let pastEndTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-39/40"], body: bytes(0..<40))
        ])
        let pastEndFetcher = RangedAudioFetcher(url: url, transport: pastEndTransport)
        _ = try? await pastEndFetcher.open()
        do {
            _ = try await pastEndFetcher.read(offset: 40, length: 1)
            check.check("an offset at the file's total length throws invalidRange", false)
        } catch RangedAudioFetcherError.invalidRange {
            check.check("an offset at the file's total length throws invalidRange", true)
        } catch {
            check.check("an offset at the file's total length throws invalidRange, not \(error)", false)
        }
        check.equal(
            "rejecting an out-of-range offset issues no additional fetch",
            pastEndTransport.requestedRanges.count,
            1
        )
    }

    await check.suite("RangedAudioFetcher: sparse store gap-filling and coalescing") {
        let transport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-65535/200000"], body: bytes(0..<65536)),
            .response(
                status: 206,
                headers: ["Content-Range": "bytes 65536-131071/200000"],
                body: bytes(65_536..<131_072)
            ),
        ])
        let fetcher = RangedAudioFetcher(url: url, transport: transport)
        _ = try? await fetcher.open()

        try? await fetcher.prefetch(from: 0, upTo: 131_071)
        check.equal(
            "prefetch to a horizon after open() fetches only the missing tail range",
            transport.requestedRanges,
            [0...65_535, 65_536...131_071]
        )

        try? await fetcher.prefetch(from: 0, upTo: 131_071)
        check.equal(
            "two adjacent stores coalesce: a repeat prefetch over the same range issues no request",
            transport.requestedRanges.count,
            2
        )

        let alreadyDownloaded = try? await fetcher.read(offset: 100, length: 50)
        check.equal(
            "a read of an already-downloaded interval returns the bytes with no extra fetch",
            alreadyDownloaded,
            bytes(100..<150)
        )
        check.equal("no extra fetch was issued", transport.requestedRanges.count, 2)
    }

    await check.suite("RangedAudioFetcher: prefetch(from:upTo:) never fills from file start unless asked") {
        let transport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-65535/200000"], body: bytes(0..<65536)),
            .response(
                status: 206,
                headers: ["Content-Range": "bytes 70000-135535/200000"],
                body: bytes(70_000..<135_536)
            ),
        ])
        let fetcher = RangedAudioFetcher(url: url, transport: transport)
        // Nothing has been downloaded yet: prefetching a window starting at 70,000 still needs
        // `open()` to bootstrap the file's total length (unavoidable — that's the only way to
        // learn it), but the window it actually fetches for the request itself starts at
        // 70,000, not back at the start of the file.
        try? await fetcher.prefetch(from: 70_000, upTo: 70_010)
        check.equal(
            "prefetch(from:upTo:) fetches the requested window, not the whole file from 0",
            transport.requestedRanges.last,
            70_000...135_535
        )
        check.equal(
            "only the bootstrap open() and the requested window were fetched",
            transport.requestedRanges.count,
            2
        )
    }

    await check.suite("RangedAudioFetcher: a capped 206 response is followed until the request is covered") {
        // The CDN can return less than requested in a single 206 even when more of the file
        // remains; `fetchAndStore` must keep asking for the rest. Setting up a stored segment
        // starting at byte 10 (via a first response that itself, unusually, starts partway
        // into what was requested — `store` always trusts the response's own `Content-Range`,
        // not the request's lower bound) lets a later request for byte 0 get widened only up
        // to byte 9, so the capped-response scenario plays out on a small, easy-to-follow range.
        let transport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 10-39/40"], body: bytes(10..<40)),
            .response(status: 206, headers: ["Content-Range": "bytes 0-4/40"], body: bytes(0..<5)),
            .response(status: 206, headers: ["Content-Range": "bytes 5-9/40"], body: bytes(5..<10)),
        ])
        let fetcher = RangedAudioFetcher(url: url, transport: transport)
        _ = try? await fetcher.open()

        let firstByte = try? await fetcher.read(offset: 0, length: 1)
        check.equal("the gap fills in via continuation and the byte reads back correctly", firstByte, bytes(0..<1))
        check.equal(
            "the widened request for the gap is capped at the next stored segment (byte 9)",
            transport.requestedRanges[1],
            0...9
        )
        check.equal(
            "a 206 covering less than requested causes a follow-up request for the remainder",
            transport.requestedRanges[2],
            5...9
        )

        let mismatchedTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-9/40"], body: bytes(0..<3))
        ])
        await expectThrown(check, "a body shorter than Content-Range claims", .unparseableContentRange) {
            _ = try await RangedAudioFetcher(url: url, transport: mismatchedTransport).open()
        }
    }

    await check.suite("RangedAudioFetcher: header lookups are case-insensitive") {
        let lowercaseTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["content-range": "bytes 0-9/10"], body: bytes(0..<10))
        ])
        let opened = try? await RangedAudioFetcher(url: url, transport: lowercaseTransport).open()
        check.equal("a lowercase content-range header still parses", opened, 10)

        let pastDateSleeper = RecordingDurationSleeper()
        let pastDateTransport = ScriptedRangedTransport(steps: [
            .response(status: 429, headers: ["retry-after": "Sun, 06 Nov 1994 08:49:37 GMT"], body: Data()),
            .response(status: 206, headers: ["Content-Range": "bytes 0-9/10"], body: bytes(0..<10)),
        ])
        let pastDateFetcher = RangedAudioFetcher(url: url, transport: pastDateTransport, sleep: pastDateSleeper.sleep)
        let pastDateOpened = try? await pastDateFetcher.open()
        check.equal("a 429 with a past HTTP-date Retry-After still succeeds", pastDateOpened, 10)
        check.equal("a past HTTP-date Retry-After retries with no delay", pastDateSleeper.delays, [.seconds(0)])
    }
}

/// Bytes `0...255` cycling, so fixture ranges are self-describing without a giant literal.
private func bytes(_ range: Range<Int>) -> Data {
    Data(range.map { UInt8(truncatingIfNeeded: $0) })
}

@MainActor
private func expectThrown(
    _ check: CheckRunner,
    _ label: String,
    _ expected: RangedAudioFetcherError,
    perform: () async throws -> Void
) async {
    do {
        try await perform()
        check.check("\(label) throws", false)
    } catch let error as RangedAudioFetcherError {
        check.equal(label, error, expected)
    } catch {
        check.check("\(label) throws RangedAudioFetcherError, got \(error)", false)
    }
}

private final class ScriptedRangedTransport: RangedHTTPTransport, @unchecked Sendable {
    enum Step {
        case response(status: Int, headers: [String: String], body: Data)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var ranges: [ClosedRange<Int>] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    var requestedRanges: [ClosedRange<Int>] {
        lock.withLock { ranges }
    }

    func fetch(_ url: URL, range: ClosedRange<Int>) async throws -> RangedHTTPResponse {
        let step: Step = lock.withLock {
            ranges.append(range)
            return steps.isEmpty ? .response(status: 500, headers: [:], body: Data()) : steps.removeFirst()
        }
        switch step {
        case let .response(status, headers, body):
            return RangedHTTPResponse(statusCode: status, headers: headers, body: body)
        }
    }
}

private final class RecordingDurationSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var delays: [Duration] {
        lock.withLock { recorded }
    }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { recorded.append(duration) }
    }
}
