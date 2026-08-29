import AuralDomain
import Foundation
@testable import AuralCore

private enum WalkProbe: Error, Equatable {
    case boom
}

@MainActor
func runPaginationWalkChecks(_ check: CheckRunner) async {
    await check.suite("Bounded pagination collect") {
        let ordinary = OffsetRecorder()
        await expectCollect(
            check,
            "ordinary totalCount concatenates pages in order",
            expected: [0, 1, 2]
        ) { offset in
            ordinary.record(offset)
            if offset == 0 {
                return Pagination.Page(items: [0, 1], pageEntryCount: 2, totalCount: 3)
            }
            return Pagination.Page(items: [2], pageEntryCount: 1, totalCount: 3)
        }
        check.equal("ordinary totalCount fetches each named offset once", ordinary.values, [0, 2])

        let boundary = OffsetRecorder()
        await expectCollect(
            check,
            "exact page-boundary totalCount does not fetch past the last page",
            expected: [0, 1, 2, 3]
        ) { offset in
            boundary.record(offset)
            return Pagination.Page(
                items: [offset, offset + 1],
                pageEntryCount: 2,
                totalCount: 4
            )
        }
        check.equal("exact page-boundary fetches two pages", boundary.values, [0, 2])

        await expectCollect(
            check,
            "omitted totalCount ends on a final empty page",
            expected: [0, 1]
        ) { offset in
            if offset == 0 {
                return Pagination.Page(items: [0, 1], pageEntryCount: 2, totalCount: nil)
            }
            return Pagination.Page(items: [], pageEntryCount: 0, totalCount: nil)
        }

        await expectCollect(
            check,
            "empty first page yields no items",
            expected: []
        ) { _ in
            Pagination.Page(items: [Int](), pageEntryCount: 0, totalCount: 0)
        }

        let zeroCap = OffsetRecorder()
        await expectCollectFailure(
            check,
            "a zero page cap fails before any fetch",
            Pagination.Failure.pageLimitReached
        ) {
            try await Pagination.collect(maximumPageCount: 0) { offset in
                zeroCap.record(offset)
                return Pagination.Page(items: [offset], pageEntryCount: 0, totalCount: 0)
            }
        }
        check.equal("a zero page cap does not fetch", zeroCap.values, [])

        let capOffsets = OffsetRecorder()
        await expectCollectFailure(
            check,
            "cap exhaustion fails instead of returning a partial list",
            Pagination.Failure.pageLimitReached
        ) {
            try await Pagination.collect(maximumPageCount: 2) { offset in
                capOffsets.record(offset)
                return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: nil)
            }
        }
        check.equal("cap exhaustion fetches exactly the allowed pages", capOffsets.values, [0, 1])

        let stalled = OffsetRecorder()
        await expectCollectFailure(
            check,
            "a non-progressing offset fails rather than looping",
            Pagination.Failure.offsetDidNotAdvance
        ) {
            try await Pagination.collect(
                maximumPageCount: 4,
                nextOffset: { offset, _, _ in offset }
            ) { offset in
                stalled.record(offset)
                return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: nil)
            }
        }
        check.equal("a non-progressing response is fetched once", stalled.values, [0])

        let thrown = OffsetRecorder()
        await expectThrown(
            check,
            "fetch errors propagate without a partial success",
            WalkProbe.boom
        ) {
            _ = try await Pagination.collect { offset in
                thrown.record(offset)
                if offset > 0 { throw WalkProbe.boom }
                return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: 10)
            }
        }
        check.equal("a mid-walk error stops after the failing page", thrown.values, [0, 1])

        let parked = ReleaseGate()
        let fetches = OffsetRecorder()
        let pending = Task {
            try await Pagination.collect { offset in
                fetches.record(offset)
                if offset > 0 {
                    await parked.park()
                    try Task.checkCancellation()
                }
                return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: 10)
            }
        }
        await parked.waitUntilEntered()
        pending.cancel()
        parked.open()
        var cancelled = false
        do {
            _ = try await pending.value
        } catch is CancellationError {
            cancelled = true
        } catch {
            check.check("cancellation stays CancellationError, got \(error)", false)
        }
        check.check("cancelling a walk surfaces CancellationError", cancelled)
        check.equal("cancellation does not fetch past the parked page", fetches.values, [0, 1])
    }

    await check.suite("PartnerAPI paged walks") {
        let playlistTransport = ScriptedOffsetTransport { operation, offset in
            guard operation == "fetchPlaylist" else { return (500, Data()) }
            return (200, playlistPage(offset: offset, totalCount: 2))
        }
        let playlist = try? await partnerAPI(transport: playlistTransport.send).playlist(id: "pl")
        check.equal(
            "playlist concatenates pages in order",
            playlist?.content?.items?.compactMap(\.uid),
            ["uid-0", "uid-1"]
        )
        check.equal("playlist freezes totalCount from the first page", playlist?.content?.totalCount, 2)
        check.equal("playlist walks exactly the named pages", playlistTransport.offsets(for: "fetchPlaylist"), [0, 1])

        let tracksTransport = ScriptedOffsetTransport { operation, offset in
            guard operation == "fetchLibraryTracks" else { return (500, Data()) }
            if offset == 0 {
                return (200, libraryTracksPage(offset: offset, totalCount: nil, itemCount: 1))
            }
            return (200, libraryTracksPage(offset: offset, totalCount: nil, itemCount: 0))
        }
        let tracks = try? await partnerAPI(transport: tracksTransport.send).libraryTracks()
        check.equal(
            "libraryTracks omitted totalCount ends on an empty page",
            tracks?.compactMap(\.track?.uri),
            ["spotify:track:t0"]
        )
        check.equal(
            "libraryTracks requests the empty terminator",
            tracksTransport.offsets(for: "fetchLibraryTracks"),
            [0, 1]
        )

        let playlistsTransport = ScriptedOffsetTransport { operation, offset in
            guard operation == "libraryV3" else { return (500, Data()) }
            return (200, libraryEntitiesPage(itemCount: offset == 0 ? 0 : 1, totalCount: 0))
        }
        let playlists = try? await partnerAPI(transport: playlistsTransport.send).libraryPlaylists()
        check.equal("empty first library page yields no playlists", playlists?.count, 0)
        check.equal("empty first library page does not continue", playlistsTransport.offsets(for: "libraryV3"), [0])

        let failed = ScriptedOffsetTransport { operation, offset in
            guard operation == "fetchLibraryTracks" else { return (500, Data()) }
            if offset == 0 {
                return (200, libraryTracksPage(offset: 0, totalCount: 10, itemCount: 1))
            }
            return (503, Data(#"{"error":"AURAL_PRIVACY_SENTINEL_api-body_d81f"}"#.utf8))
        }
        await expectThrown(
            check,
            "a mid-walk HTTP error stays typed",
            PartnerAPIError.requestFailed(503)
        ) {
            _ = try await partnerAPI(transport: failed.send).libraryTracks()
        }
        check.equal("a mid-walk HTTP error does not fetch further pages", failed.offsets(for: "fetchLibraryTracks"), [0, 1])
    }
}

private func partnerAPI(transport: @escaping SpotifyCredentials.Transport) -> PartnerAPI {
    PartnerAPI(
        accessToken: { "fixture-access" },
        clientToken: { "fixture-client" },
        invalidateAccessToken: { _ in },
        invalidateClientToken: { _ in },
        transport: transport
    )
}

@MainActor
private func expectCollect(
    _ check: CheckRunner,
    _ label: String,
    expected: [Int],
    fetchPage: @escaping (Int) async throws -> Pagination.Page<Int>
) async {
    do {
        let items = try await Pagination.collect(maximumPageCount: 8, fetchPage: fetchPage)
        check.equal(label, items, expected)
    } catch {
        check.check("\(label) succeeds, got \(error)", false)
    }
}

@MainActor
private func expectCollectFailure(
    _ check: CheckRunner,
    _ label: String,
    _ expected: Pagination.Failure,
    perform: () async throws -> [Int]
) async {
    do {
        _ = try await perform()
        check.check("\(label) throws", false)
    } catch let failure as Pagination.Failure {
        check.equal(label, failure, expected)
    } catch {
        check.check("\(label) throws Pagination.Failure, got \(error)", false)
    }
}

@MainActor
private func expectThrown<Failure: Error & Equatable>(
    _ check: CheckRunner,
    _ label: String,
    _ expected: Failure,
    perform: () async throws -> Void
) async {
    do {
        try await perform()
        check.check("\(label) throws", false)
    } catch let error as Failure {
        check.equal(label, error, expected)
    } catch {
        check.check("\(label) throws \(Failure.self), got \(error)", false)
    }
}

private func playlistPage(offset: Int, totalCount: Int) -> Data {
    Data(
        """
        {"data":{"playlistV2":{"uri":"spotify:playlist:pl","name":"Mix","content":{"totalCount":\(totalCount),"items":[{"uid":"uid-\(offset)","itemV2":{"data":{"uri":"spotify:track:t\(offset)","name":"T\(offset)"}}}]}}}}
        """.utf8
    )
}

private func libraryTracksPage(offset: Int, totalCount: Int?, itemCount: Int) -> Data {
    let total = totalCount.map { "\"totalCount\":\($0)," } ?? ""
    let items: String
    if itemCount == 0 {
        items = "[]"
    } else {
        items = "[{\"track\":{\"_uri\":\"spotify:track:t\(offset)\",\"data\":{\"name\":\"T\(offset)\"}}}]"
    }
    return Data(
        """
        {"data":{"me":{"library":{"tracks":{\(total)"items":\(items)}}}}}
        """.utf8
    )
}

private func libraryEntitiesPage(itemCount: Int, totalCount: Int) -> Data {
    let items: String
    if itemCount == 0 {
        items = "[]"
    } else {
        items = "[{\"item\":{\"data\":{\"uri\":\"spotify:playlist:p0\",\"name\":\"P0\"}}}]"
    }
    return Data(
        """
        {"data":{"me":{"libraryV3":{"totalCount":\(totalCount),"items":\(items)}}}}
        """.utf8
    )
}

private struct PathfinderOffsetProbe: Decodable {
    struct Variables: Decodable {
        let offset: Int?
    }

    let operationName: String
    let variables: Variables
}

private final class OffsetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    var values: [Int] {
        lock.withLock { recorded }
    }

    func record(_ offset: Int) {
        lock.lock()
        recorded.append(offset)
        lock.unlock()
    }
}

private final class ReleaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered: CheckedContinuation<Void, Never>?
    private var parked: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var released = false

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasEntered {
                lock.unlock()
                continuation.resume()
            } else {
                entered = continuation
                lock.unlock()
            }
        }
    }

    func park() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            hasEntered = true
            let enteredWaiter = entered
            entered = nil
            if released {
                lock.unlock()
                enteredWaiter?.resume()
                continuation.resume()
            } else {
                parked = continuation
                lock.unlock()
                enteredWaiter?.resume()
            }
        }
    }

    func open() {
        lock.lock()
        released = true
        let parked = parked
        self.parked = nil
        lock.unlock()
        parked?.resume()
    }
}

private final class ScriptedOffsetTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String: [Int]] = [:]
    private let response: @Sendable (String, Int) -> (Int, Data)

    init(response: @escaping @Sendable (String, Int) -> (Int, Data)) {
        self.response = response
    }

    func offsets(for operation: String) -> [Int] {
        lock.withLock { recorded[operation] ?? [] }
    }

    var send: SpotifyCredentials.Transport {
        { [self] request in
            try self.step(request)
        }
    }

    private func step(_ request: URLRequest) throws -> (Data, URLResponse) {
        let probe = try JSONDecoder().decode(PathfinderOffsetProbe.self, from: request.httpBody ?? Data())
        let offset = probe.variables.offset ?? 0
        lock.lock()
        recorded[probe.operationName, default: []].append(offset)
        lock.unlock()
        let (status, body) = response(probe.operationName, offset)
        let url = request.url ?? URL(string: "https://example.invalid/")!
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
