import AuralDomain
import Foundation
@testable import AuralCore

private let privacySentinel = "AURAL_PRIVACY_SENTINEL_api-body_d81f"

@MainActor
private func omitSentinel(_ check: CheckRunner, _ label: String, _ text: String?) {
    check.notNil(label, text)
    check.check("\(label) omits the response body", text?.contains(privacySentinel) != true)
}

private func httpResponse(url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

private func rejectedTransport(status: Int, body: Data) -> SpotifyCredentials.Transport {
    { @Sendable request in
        (body, httpResponse(url: request.url ?? URL(string: "https://example.invalid/")!, status: status))
    }
}

private func partnerAPI(status: Int, body: String) -> PartnerAPI {
    PartnerAPI(
        accessToken: { "fixture-access" },
        clientToken: { "fixture-client" },
        invalidateClientToken: { _ in },
        transport: rejectedTransport(status: status, body: Data(body.utf8)),
        retryTiming: .immediate
    )
}

@MainActor
private func expectFailure<Failure: Error & Equatable & LocalizedError>(
    _ check: CheckRunner,
    _ label: String,
    _ expected: Failure,
    description: String,
    perform: () async throws -> Void
) async {
    do {
        try await perform()
        check.check("\(label) throws", false)
    } catch let error as Failure {
        check.equal("\(label) keeps typed case", error, expected)
        check.equal("\(label) uses a stable category", error.errorDescription ?? "", description)
        omitSentinel(check, "\(label) LocalizedError", error.errorDescription)
    } catch {
        check.check("\(label) throws \(Failure.self), got \(error)", false)
    }
}

@MainActor
func runPrivacySanitizationChecks(_ check: CheckRunner) async {
    await check.suite("API failure privacy") {
        let clientToken = ClientTokenError.requestFailed(401)
        check.equal(
            "client-token failures keep HTTP status",
            clientToken,
            .requestFailed(401)
        )
        check.equal(
            "client-token failures use a stable HTTP category",
            clientToken.errorDescription ?? "",
            "Could not obtain a Spotify client token (HTTP 401)"
        )
        omitSentinel(check, "client-token LocalizedError", clientToken.errorDescription)

        await expectFailure(
            check,
            "Partner HTTP",
            PartnerAPIError.requestFailed(503),
            description: "Spotify rejected the request (HTTP 503)",
            perform: { _ = try await partnerAPI(status: 503, body: "{\"error\":\"\(privacySentinel)\"}").profile() }
        )

        await expectFailure(
            check,
            "Partner GraphQL",
            PartnerAPIError.graphQLErrors,
            description: "Spotify returned a GraphQL error",
            perform: {
                _ = try await partnerAPI(
                    status: 200,
                    body: """
                    {"errors":[{"message":"\(privacySentinel)","extensions":{"code":"INTERNAL"}}]}
                    """
                ).profile()
            }
        )

        await expectFailure(
            check,
            "retired persisted query",
            PartnerAPIError.persistedQueryNotFound("profileAttributes"),
            description: "Spotify no longer recognises the stored query for profileAttributes",
            perform: {
                _ = try await partnerAPI(
                    status: 200,
                    body: """
                    {"errors":[{"message":"\(privacySentinel) persistedQueryNotFound","extensions":{"code":"PERSISTED_QUERY_NOT_FOUND"}}]}
                    """
                ).profile()
            }
        )

        await expectFailure(
            check,
            "Partner mutation",
            PartnerAPIError.mutationRejected("addToLibrary"),
            description: "Spotify rejected addToLibrary",
            perform: {
                try await partnerAPI(
                    status: 200,
                    body: """
                    {"data":{"addLibraryItems":{"__typename":"NotFound","message":"\(privacySentinel)"}}}
                    """
                ).addToLibrary(uris: ["spotify:track:fixture"])
            }
        )

        check.equal(
            "pagination cap failures keep a stable category",
            PartnerAPIError.pagination(.pageLimitReached),
            .pagination(.pageLimitReached)
        )
        check.equal(
            "pagination cap failures omit payloads",
            PartnerAPIError.pagination(.pageLimitReached).errorDescription ?? "",
            "Spotify pagination exceeded the request limit"
        )
        omitSentinel(
            check,
            "pagination cap LocalizedError",
            PartnerAPIError.pagination(.pageLimitReached).errorDescription
        )
        check.equal(
            "pagination non-progress failures omit payloads",
            PartnerAPIError.pagination(.offsetDidNotAdvance).errorDescription ?? "",
            "Spotify pagination did not advance"
        )
        omitSentinel(
            check,
            "pagination non-progress LocalizedError",
            PartnerAPIError.pagination(.offsetDidNotAdvance).errorDescription
        )

        let connect = SpotifyConnectAPI(
            accessToken: { "fixture-access" },
            clientToken: { "fixture-client" },
            invalidateClientToken: { _ in },
            transport: rejectedTransport(status: 502, body: Data(privacySentinel.utf8)),
            retryTiming: .immediate
        )
        await expectFailure(
            check,
            "Connect",
            SpotifyConnectAPIError.requestFailed(502),
            description: "Spotify rejected the command (HTTP 502)",
            perform: { try await connect.send(.pause, from: "source", to: "target") }
        )

        let queue = SpotifyWebPlayerAPI(
            accessToken: { "fixture-access" },
            transport: rejectedTransport(
                status: 429,
                body: Data("{\"error\":\"\(privacySentinel)\"}".utf8)
            ),
            retryTiming: .immediate
        )
        await expectFailure(
            check,
            "queue Web API",
            SpotifyWebPlayerAPIError.requestFailed(429),
            description: "Spotify rejected the queue request (HTTP 429)",
            perform: { _ = try await queue.queue() }
        )
        do {
            _ = try await SpotifyWebPlayerAPI(
                accessToken: { "fixture-access" },
                transport: rejectedTransport(status: 403, body: Data(privacySentinel.utf8)),
                retryTiming: .immediate
            ).queue()
            check.check("forbidden queue failures throw", false)
        } catch let error as SpotifyWebPlayerAPIError {
            check.equal("401/403 capability still reads status", error.statusCode ?? -1, 403)
            omitSentinel(check, "forbidden queue LocalizedError", error.errorDescription)
        } catch {
            check.check("forbidden queue failures throw SpotifyWebPlayerAPIError", false)
        }

        let attributes = TrackAttributesAPI(
            accessToken: { "fixture-access" },
            clientToken: { "fixture-client" },
            invalidateClientToken: { _ in },
            transport: rejectedTransport(status: 500, body: Data(privacySentinel.utf8)),
            retryTiming: .immediate
        )
        await expectFailure(
            check,
            "track-attribute",
            TrackAttributesAPIError.requestFailed(500),
            description: "Spotify rejected the attribute request (HTTP 500)",
            perform: {
                _ = try await attributes.attributes(for: ["spotify:track:6rqhFgbbKwnb9MLmUQDhG6"])
            }
        )

        let failedPhase = PlaybackSessionPhase.failed(
            PartnerAPIError.requestFailed(503).errorDescription ?? privacySentinel
        )
        check.equal("failed session phases log a stable category", sessionPhaseLogLabel(failedPhase), "failed")
        omitSentinel(check, "session phase public log label", sessionPhaseLogLabel(failedPhase))
        let publicLog = "Session phase changed: \(sessionPhaseLogLabel(.ready)) -> \(sessionPhaseLogLabel(failedPhase)); epoch=8"
        omitSentinel(check, "public session phase log", publicLog)
        check.check("session phase logs keep epoch", publicLog.contains("epoch=8"))
    }
}
