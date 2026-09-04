import Foundation
@testable import AuralCore

@MainActor
func runRangedAudioFetcherChecks(_ check: CheckRunner) async {
    await check.suite("RangedAudioFetcher") {
        let url = URL(string: "https://audio-ak.spotifycdn.com/audio/fixture")!

        let openTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-9/40"], body: bytes(0..<10))
        ])
        let opened = try? await RangedAudioFetcher(url: url, transport: openTransport).open()
        check.equal("open() returns the total length parsed from Content-Range", opened, 40)
        check.equal("open() fetches exactly one range", openTransport.requestedRanges.count, 1)
        check.equal("open() requests from byte 0", openTransport.requestedRanges.first?.lowerBound, 0)

        let readWithinTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-9/40"], body: bytes(0..<10))
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

        // A file much larger than the minimum chunk: a small missing read still fetches at
        // least `initialChunk` bytes, not just the bytes actually asked for.
        let minimumChunkTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-9/200000"], body: bytes(0..<10)),
            .response(status: 206, headers: ["Content-Range": "bytes 10-65545/200000"], body: Data()),
        ])
        let minimumChunkFetcher = RangedAudioFetcher(url: url, transport: minimumChunkTransport)
        _ = try? await minimumChunkFetcher.open()
        _ = try? await minimumChunkFetcher.read(offset: 10, length: 5)
        check.equal(
            "a missing read fetches at least the minimum chunk size",
            minimumChunkTransport.requestedRanges.last,
            10...65_545
        )

        // A file where the minimum chunk would overrun the end: the fetch clamps to the last byte.
        let clampToEndTransport = ScriptedRangedTransport(steps: [
            .response(status: 206, headers: ["Content-Range": "bytes 0-9/20"], body: bytes(0..<10)),
            .response(status: 206, headers: ["Content-Range": "bytes 15-19/20"], body: bytes(15..<20)),
        ])
        let clampToEndFetcher = RangedAudioFetcher(url: url, transport: clampToEndTransport)
        _ = try? await clampToEndFetcher.open()
        _ = try? await clampToEndFetcher.read(offset: 15, length: 5)
        check.equal(
            "a missing read near the end clamps to the file's last byte, not past it",
            clampToEndTransport.requestedRanges.last,
            15...19
        )

        let retrySleeper = RecordingDurationSleeper()
        let retryTransport = ScriptedRangedTransport(steps: [
            .response(status: 429, headers: ["Retry-After": "1"], body: Data()),
            .response(status: 206, headers: ["Content-Range": "bytes 0-9/40"], body: bytes(0..<10)),
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

        let unexpectedTransport = ScriptedRangedTransport(steps: [.response(status: 200, headers: [:], body: Data())])
        do {
            _ = try await RangedAudioFetcher(url: url, transport: unexpectedTransport).open()
            check.check("an unexpected status throws unexpectedStatus", false)
        } catch RangedAudioFetcherError.unexpectedStatus(200) {
            check.check("an unexpected status throws unexpectedStatus", true)
        } catch {
            check.check("an unexpected status throws unexpectedStatus, not \(error)", false)
        }
    }
}

/// Bytes `0...255` cycling, so fixture ranges are self-describing without a giant literal.
private func bytes(_ range: Range<Int>) -> Data {
    Data(range.map { UInt8(truncatingIfNeeded: $0) })
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
