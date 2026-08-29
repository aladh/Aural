import AuralDomain
import Foundation
@testable import AuralCore

@MainActor
func runPaginationWalkChecks(_ check: CheckRunner) async {
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
