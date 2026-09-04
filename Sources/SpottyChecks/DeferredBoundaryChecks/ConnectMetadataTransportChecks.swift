import SpottyDomain
import Foundation
@testable import SpottyCore

private let fixtureURI = "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
private let otherFixtureURI = "spotify:track:0000000000000000000001"

private let metadataBody = Data(
    #"{"name":"Fixture Title","artist":[{"name":"First"},{"name":"Second"}],"album":{"cover_group":{"image":[{"file_id":"small","width":64,"height":64},{"file_id":"large","width":300,"height":300}]}},"duration":123000}"#
        .utf8
)

@MainActor
func runConnectMetadataTransportChecks(_ check: CheckRunner) async {
    await check.suite("Connect metadata is one signed GET") {
        let transport = RecordingConnectTransport(steps: [.http(status: 200, body: metadataBody)])
        let metadata: SpotifyConnectTrackMetadata?
        do {
            metadata = try await connectAPI(transport: transport.send).trackMetadata(for: fixtureURI)
        } catch {
            check.check("successful metadata throws \(error)", false)
            metadata = nil
        }

        check.equal("title is decoded", metadata?.title, "Fixture Title")
        check.equal("artists are joined", metadata?.artist, "First, Second")
        check.equal("duration is milliseconds", metadata?.duration, 123.0)
        check.equal(
            "largest cover becomes the artwork URL",
            metadata?.artworkURL,
            URL(string: "https://i.scdn.co/image/large")
        )
        check.equal("the requested URI is preserved", metadata?.uri, fixtureURI)
        check.equal("successful metadata is one GET", transport.methods, ["GET"])
        check.equal("successful metadata is one attempt", transport.callCount, 1)
        check.check(
            "the GET is the metadata track path",
            transport.paths.allSatisfy { path in
                path.hasPrefix("/metadata/4/track/") && path.contains("market=from_token")
            })
        check.equal("the GET carries the bearer", transport.authorizationTokens, ["fixture-access"])
        check.equal("the GET carries the client token", transport.clientTokens, ["fixture-client"])
        check.equal("the GET is desktop-client signed", transport.appPlatforms, [SpotifyCredentials.appPlatform])
        check.equal("the GET carries the xpui origin", transport.origins, [SpotifyCredentials.origin])
    }

    await check.suite("Concurrent metadata fetches do not emit OPTIONS") {
        let transport = RecordingConnectTransport(steps: [
            .http(status: 200, body: metadataBody),
            .http(status: 200, body: metadataBody),
        ])
        let api = connectAPI(transport: transport.send)
        async let first = api.trackMetadata(for: fixtureURI)
        async let second = api.trackMetadata(for: otherFixtureURI)
        let titles = [(try? await first)?.title, (try? await second)?.title]

        check.check("both concurrent fetches succeed", titles.allSatisfy { $0 == "Fixture Title" })
        check.equal("two tracks are two GETs", transport.methods, ["GET", "GET"])
        check.equal("two tracks are two attempts", transport.callCount, 2)
        check.check("distinct track URLs stay distinct", Set(transport.paths).count == 2)
    }

    await check.suite("Connect metadata replay budget stays GET") {
        let budget = SpotifyTransientRetry.maximumAttempts
        let exhausted = RecordingConnectTransport(
            steps: Array(repeating: .http(status: 502, body: Data()), count: budget)
        )
        await expectThrown(
            check,
            "HTTP 502 stays requestFailed after the budget",
            SpotifyConnectAPIError.requestFailed(502)
        ) {
            _ = try await connectAPI(transport: exhausted.send).trackMetadata(for: fixtureURI)
        }
        check.equal(
            "every replayable attempt is GET",
            exhausted.methods,
            Array(repeating: "GET", count: budget)
        )
    }

    await check.suite("Connect metadata decoder failures") {
        let unused = RecordingConnectTransport(steps: [.http(status: 200, body: metadataBody)])
        await expectThrown(
            check,
            "an invalid track URI never hits the wire",
            SpotifyConnectAPIError.invalidTrackURI
        ) {
            _ = try await connectAPI(transport: unused.send).trackMetadata(for: "spotify:album:not-a-track")
        }
        check.equal("invalid URI is zero attempts", unused.callCount, 0)

        let malformed = RecordingConnectTransport(steps: [.http(status: 200, body: Data("{}".utf8))])
        await expectThrown(
            check,
            "an empty JSON object is malformed",
            SpotifyConnectAPIError.malformedResponse
        ) {
            _ = try await connectAPI(transport: malformed.send).trackMetadata(for: fixtureURI)
        }
        check.equal("malformed JSON is one GET", malformed.methods, ["GET"])

        let emptyTitle = RecordingConnectTransport(steps: [
            .http(status: 200, body: Data(#"{"name":""}"#.utf8))
        ])
        await expectThrown(
            check,
            "an empty title is malformed",
            SpotifyConnectAPIError.malformedResponse
        ) {
            _ = try await connectAPI(transport: emptyTitle.send).trackMetadata(for: fixtureURI)
        }
        check.equal("empty title is one GET", emptyTitle.methods, ["GET"])
    }
}

private func connectAPI(transport: @escaping SpotifyCredentials.Transport) -> SpotifyConnectAPI {
    SpotifyConnectAPI(
        accessToken: { "fixture-access" },
        clientToken: { "fixture-client" },
        invalidateAccessToken: { _ in },
        invalidateClientToken: { _ in },
        transport: transport,
        retryTiming: .immediate
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

private enum ConnectTransportStep {
    case http(status: Int, body: Data = Data(), headers: [String: String] = [:])
}

private final class RecordingConnectTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let steps: [ConnectTransportStep]
    private var index = 0
    private var recordedMethods: [String] = []
    private var recordedPaths: [String] = []
    private var authorizations: [String] = []
    private var clients: [String] = []
    private var platforms: [String] = []
    private var recordedOrigins: [String] = []

    init(steps: [ConnectTransportStep]) {
        self.steps = steps
    }

    var callCount: Int {
        lock.withLock { index }
    }

    var methods: [String] {
        lock.withLock { recordedMethods }
    }

    var paths: [String] {
        lock.withLock { recordedPaths }
    }

    var authorizationTokens: [String] {
        lock.withLock { authorizations }
    }

    var clientTokens: [String] {
        lock.withLock { clients }
    }

    var appPlatforms: [String] {
        lock.withLock { platforms }
    }

    var origins: [String] {
        lock.withLock { recordedOrigins }
    }

    var send: SpotifyCredentials.Transport {
        { [self] request in
            try self.step(request)
        }
    }

    private func step(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        recordedMethods.append(request.httpMethod ?? "GET")
        if let url = request.url {
            recordedPaths.append(url.path + (url.query.map { "?\($0)" } ?? ""))
        }
        if let access = SpotifyCredentials.accessTokenCarried(by: request) {
            authorizations.append(access)
        }
        if let client = request.value(forHTTPHeaderField: "Client-Token") {
            clients.append(client)
        }
        if let platform = request.value(forHTTPHeaderField: "App-Platform") {
            platforms.append(platform)
        }
        if let origin = request.value(forHTTPHeaderField: "Origin") {
            recordedOrigins.append(origin)
        }
        let url = request.url ?? URL(string: "https://example.invalid/")!
        guard index < steps.count else {
            index += 1
            return (
                Data(),
                HTTPURLResponse(url: url, statusCode: 598, httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
        let step = steps[index]
        index += 1
        switch step {
        case let .http(status, body, headers):
            return (
                body,
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            )
        }
    }
}
