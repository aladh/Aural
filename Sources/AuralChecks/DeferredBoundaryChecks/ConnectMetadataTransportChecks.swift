import AuralDomain
import Foundation
@testable import AuralCore

private let fixtureURI = "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
private let otherFixtureURI = "spotify:track:0000000000000000000001"
private let privacySentinel = "AURAL_PRIVACY_SENTINEL_connect-metadata_61"

private let metadataBody = Data(
    """
    {
      "name": "Fixture Title",
      "artist": [{"name": "First"}, {"name": "Second"}],
      "album": {
        "cover_group": {
          "image": [
            {"file_id": "small", "width": 64, "height": 64},
            {"file_id": "large", "width": 300, "height": 300}
          ]
        }
      },
      "duration": 123000
    }
    """.utf8
)

@MainActor
func runConnectMetadataTransportChecks(_ check: CheckRunner) async {
    await check.suite("Connect metadata is one signed GET") {
        let transport = RecordingConnectTransport(steps: [.http(status: 200, body: metadataBody)])
        let metadata = try? await connectAPI(transport: transport.send).trackMetadata(for: fixtureURI)

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
        check.check("the GET is the metadata track path", transport.paths.allSatisfy { path in
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
        check.equal("concurrent fetches still carry both credentials", transport.authorizationTokens, [
            "fixture-access",
            "fixture-access",
        ])
        check.equal("concurrent fetches still carry the client token", transport.clientTokens, [
            "fixture-client",
            "fixture-client",
        ])
        check.check("distinct track URLs stay distinct", Set(transport.paths).count == 2)
    }

    await check.suite("Connect metadata 401 retries the named pair once") {
        let tokens = CredentialSequence(values: ["access-a", "access-b", "access-c"])
        let clients = CredentialSequence(values: ["client-a", "client-b", "client-c"])
        let invalidatedAccess = RecordingInvalidator()
        let invalidatedClient = RecordingInvalidator()
        let transport = RecordingConnectTransport(steps: [
            .http(status: 401, body: Data()),
            .http(status: 200, body: metadataBody),
        ])
        let metadata = try? await SpotifyConnectAPI(
            accessToken: { tokens.next() },
            clientToken: { clients.next() },
            invalidateAccessToken: { await invalidatedAccess.record($0) },
            invalidateClientToken: { await invalidatedClient.record($0) },
            transport: transport.send,
            retryTiming: .immediate
        ).trackMetadata(for: fixtureURI)

        check.equal("retry succeeds after one 401", metadata?.title, "Fixture Title")
        check.equal("the sent bearer is invalidated", await invalidatedAccess.values, ["access-a"])
        check.equal("the sent client token is invalidated", await invalidatedClient.values, ["client-a"])
        check.equal("access is fetched for the attempt and the retry", tokens.callCount, 2)
        check.equal("client token is fetched for the attempt and the retry", clients.callCount, 2)
        check.equal("401 then success is GET, GET", transport.methods, ["GET", "GET"])
        check.equal("the transport is attempted twice", transport.callCount, 2)
        check.equal("retry carries the replacement pair", transport.authorizationTokens, ["access-a", "access-b"])
        check.equal("retry carries the replacement client token", transport.clientTokens, ["client-a", "client-b"])
    }

    await check.suite("A second Connect metadata 401 stops") {
        let tokens = CredentialSequence(values: ["access-a", "access-b", "access-c"])
        let clients = CredentialSequence(values: ["client-a", "client-b", "client-c"])
        let invalidatedAccess = RecordingInvalidator()
        let invalidatedClient = RecordingInvalidator()
        let transport = RecordingConnectTransport(steps: [
            .http(status: 401, body: Data()),
            .http(status: 401, body: Data()),
            .http(status: 200, body: metadataBody),
        ])

        await expectThrown(
            check,
            "a second 401 is returned rather than retried again",
            SpotifyConnectAPIError.requestFailed(401)
        ) {
            _ = try await SpotifyConnectAPI(
                accessToken: { tokens.next() },
                clientToken: { clients.next() },
                invalidateAccessToken: { await invalidatedAccess.record($0) },
                invalidateClientToken: { await invalidatedClient.record($0) },
                transport: transport.send,
                retryTiming: .immediate
            ).trackMetadata(for: fixtureURI)
        }
        check.equal("credentials are invalidated only after the first 401", await invalidatedAccess.values, ["access-a"])
        check.equal("client token is invalidated only after the first 401", await invalidatedClient.values, ["client-a"])
        check.equal("the retry is still GET, GET", transport.methods, ["GET", "GET"])
        check.equal("the transport stops after the retry", transport.callCount, 2)
        check.equal("a third credential is never fetched", tokens.callCount, 2)
    }

    await check.suite("Connect metadata 401 drops the client token even when bearer refresh throws") {
        let tokens = CredentialSequence(values: ["access-a"])
        let clients = CredentialSequence(values: ["client-a"])
        let invalidatedClient = RecordingInvalidator()
        let transport = RecordingConnectTransport(steps: [
            .http(status: 401, body: Data()),
            .http(status: 200, body: metadataBody),
        ])

        var revoked = false
        do {
            _ = try await SpotifyConnectAPI(
                accessToken: { tokens.next() },
                clientToken: { clients.next() },
                invalidateAccessToken: { _ in throw KeymasterSessionError.grantRevoked },
                invalidateClientToken: { await invalidatedClient.record($0) },
                transport: transport.send,
                retryTiming: .immediate
            ).trackMetadata(for: fixtureURI)
        } catch KeymasterSessionError.grantRevoked {
            revoked = true
        } catch {
            check.check("bearer revoke stays grantRevoked, got \(error)", false)
        }
        check.check("a revoked bearer still surfaces grantRevoked", revoked)
        check.equal("the named client token is dropped before the bearer throw", await invalidatedClient.values, ["client-a"])
        check.equal("a terminal bearer throw is one GET", transport.methods, ["GET"])
        check.equal("a terminal bearer throw does not retry the request", transport.callCount, 1)
        check.equal("access is fetched only for the first attempt", tokens.callCount, 1)
    }

    await check.suite("Connect metadata retries a safe 429 as another GET") {
        let transport = RecordingConnectTransport(steps: [
            .http(status: 429, body: Data(), headers: ["Retry-After": "1"]),
            .http(status: 200, body: metadataBody),
        ])
        let metadata = try? await connectAPI(transport: transport.send).trackMetadata(for: fixtureURI)
        check.equal("429 then success decodes", metadata?.title, "Fixture Title")
        check.equal("429 retry is GET, GET", transport.methods, ["GET", "GET"])
        check.equal("429 retry is two attempts", transport.callCount, 2)
    }

    await check.suite("Connect metadata failures stay typed and private") {
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
            .http(status: 200, body: Data(#"{"name":""}"#.utf8)),
        ])
        await expectThrown(
            check,
            "an empty title is malformed",
            SpotifyConnectAPIError.malformedResponse
        ) {
            _ = try await connectAPI(transport: emptyTitle.send).trackMetadata(for: fixtureURI)
        }
        check.equal("empty title is one GET", emptyTitle.methods, ["GET"])

        let rejected = RecordingConnectTransport(steps: [
            .http(status: 502, body: Data(privacySentinel.utf8)),
        ])
        do {
            _ = try await connectAPI(transport: rejected.send).trackMetadata(for: fixtureURI)
            check.check("HTTP 502 throws", false)
        } catch let error as SpotifyConnectAPIError {
            check.equal("HTTP 502 stays requestFailed", error, .requestFailed(502))
            check.equal(
                "HTTP 502 uses a stable category",
                error.errorDescription ?? "",
                "Spotify rejected the command (HTTP 502)"
            )
            check.check(
                "HTTP 502 omits the response body",
                error.errorDescription?.contains(privacySentinel) != true
            )
        } catch {
            check.check("HTTP 502 throws SpotifyConnectAPIError, got \(error)", false)
        }
        check.equal("HTTP 502 is one GET", rejected.methods, ["GET"])
    }

    await check.suite("Connect commands stay a single POST") {
        let transport = RecordingConnectTransport(steps: [.http(status: 200, body: Data())])
        try? await connectAPI(transport: transport.send).send(.pause, from: "source", to: "target")
        check.equal("a command is one POST", transport.methods, ["POST"])
        check.equal("a command is one attempt", transport.callCount, 1)
        check.check(
            "the POST is the player command path",
            transport.paths == ["/connect-state/v1/player/command/from/source/to/target"]
        )
        check.equal("the POST carries the bearer", transport.authorizationTokens, ["fixture-access"])
        check.equal("the POST carries the client token", transport.clientTokens, ["fixture-client"])
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
        let step = steps[index]
        index += 1
        let url = request.url ?? URL(string: "https://example.invalid/")!
        switch step {
        case let .http(status, body, headers):
            return (
                body,
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            )
        }
    }
}

private final class CredentialSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [String]
    private var index = 0

    init(values: [String]) {
        self.values = values
    }

    var callCount: Int {
        lock.withLock { index }
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        let value = values[index]
        index += 1
        return value
    }
}

private actor RecordingInvalidator {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}
