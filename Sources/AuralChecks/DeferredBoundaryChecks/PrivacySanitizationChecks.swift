import Foundation
@testable import AuralCore

private let privacySentinel = "AURAL_PRIVACY_SENTINEL_api-body_d81f"

@MainActor
func runPrivacySanitizationChecks(_ check: CheckRunner) async {
    await check.suite("API failure privacy") {
        func omitSentinel(_ label: String, _ text: String?) {
            check.notNil(label, text)
            check.check("\(label) omits the response body", text?.contains(privacySentinel) != true)
        }

        func httpResponse(url: URL, status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        }

        let tokenBody = Data(
            #"{"error":"invalid_request","error_description":"\#(privacySentinel)","refresh_token":"rt"}"#.utf8
        )
        let tokenError = KeymasterAuth.tokenFailure(status: 400, body: tokenBody)
        check.equal("token failures keep HTTP status", tokenError, .tokenExchangeFailed(400))
        check.equal(
            "token failures use a stable HTTP category",
            tokenError.errorDescription ?? "",
            "Token exchange failed (HTTP 400)"
        )
        omitSentinel("token LocalizedError", tokenError.errorDescription)
        check.equal(
            "invalid_grant remains a distinct revoked grant",
            KeymasterAuth.tokenFailure(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)),
            .grantRevoked
        )
        check.equal(
            "revoked grants keep the session-expired copy",
            KeymasterAuthError.grantRevoked.errorDescription ?? "",
            "Session expired, please sign in again"
        )

        let partnerHTTP = PartnerAPI(
            accessToken: { "fixture-access" },
            clientToken: { "fixture-client" },
            invalidateClientToken: { _ in },
            transport: { request in
                (
                    Data("{\"error\":\"\(privacySentinel)\"}".utf8),
                    httpResponse(url: request.url ?? PartnerAPI.endpoint, status: 503)
                )
            }
        )
        do {
            _ = try await partnerHTTP.profile()
            check.check("Partner HTTP failures throw", false)
        } catch let error as PartnerAPIError {
            check.equal("Partner HTTP failures keep status", error, .requestFailed(503))
            check.equal(
                "Partner HTTP failures use a stable category",
                error.errorDescription ?? "",
                "Spotify rejected the request (HTTP 503)"
            )
            omitSentinel("Partner HTTP LocalizedError", error.errorDescription)
        } catch {
            check.check("Partner HTTP failures throw PartnerAPIError", false)
        }

        let partnerGraphQL = PartnerAPI(
            accessToken: { "fixture-access" },
            clientToken: { "fixture-client" },
            invalidateClientToken: { _ in },
            transport: { request in
                let body = Data(
                    """
                    {"errors":[{"message":"\(privacySentinel)","extensions":{"code":"INTERNAL"}}]}
                    """.utf8
                )
                return (body, httpResponse(url: request.url ?? PartnerAPI.endpoint, status: 200))
            }
        )
        do {
            _ = try await partnerGraphQL.profile()
            check.check("Partner GraphQL failures throw", false)
        } catch let error as PartnerAPIError {
            check.equal("Partner GraphQL failures stay typed", error, .graphQLErrors)
            check.equal(
                "Partner GraphQL failures use a stable category",
                error.errorDescription ?? "",
                "Spotify returned a GraphQL error"
            )
            omitSentinel("Partner GraphQL LocalizedError", error.errorDescription)
        } catch {
            check.check("Partner GraphQL failures throw PartnerAPIError", false)
        }

        let partnerRetired = PartnerAPI(
            accessToken: { "fixture-access" },
            clientToken: { "fixture-client" },
            invalidateClientToken: { _ in },
            transport: { request in
                let body = Data(
                    """
                    {"errors":[{"message":"\(privacySentinel) persistedQueryNotFound","extensions":{"code":"PERSISTED_QUERY_NOT_FOUND"}}]}
                    """.utf8
                )
                return (body, httpResponse(url: request.url ?? PartnerAPI.endpoint, status: 200))
            }
        )
        do {
            _ = try await partnerRetired.profile()
            check.check("retired persisted queries throw", false)
        } catch let error as PartnerAPIError {
            check.equal(
                "retired persisted queries stay named",
                error,
                .persistedQueryNotFound("profileAttributes")
            )
            omitSentinel("persisted-query LocalizedError", error.errorDescription)
        } catch {
            check.check("retired persisted queries throw PartnerAPIError", false)
        }

        let partnerMutation = PartnerAPI(
            accessToken: { "fixture-access" },
            clientToken: { "fixture-client" },
            invalidateClientToken: { _ in },
            transport: { request in
                let body = Data(
                    """
                    {"data":{"addLibraryItems":{"__typename":"NotFound","message":"\(privacySentinel)"}}}
                    """.utf8
                )
                return (body, httpResponse(url: request.url ?? PartnerAPI.endpoint, status: 200))
            }
        )
        do {
            try await partnerMutation.addToLibrary(uris: ["spotify:track:fixture"])
            check.check("Partner mutation failures throw", false)
        } catch let error as PartnerAPIError {
            check.equal("mutation rejections keep the operation name", error, .mutationRejected("addToLibrary"))
            check.equal(
                "mutation rejections use a stable category",
                error.errorDescription ?? "",
                "Spotify rejected addToLibrary"
            )
            omitSentinel("Partner mutation LocalizedError", error.errorDescription)
        } catch {
            check.check("Partner mutation failures throw PartnerAPIError", false)
        }

        let connect = SpotifyConnectAPI(
            accessToken: { "fixture-access" },
            clientToken: { "fixture-client" },
            invalidateClientToken: { _ in },
            transport: { request in
                (
                    Data(privacySentinel.utf8),
                    httpResponse(url: request.url ?? SpotifyConnectAPI.baseURL, status: 502)
                )
            }
        )
        do {
            try await connect.send(.pause, from: "source", to: "target")
            check.check("Connect command failures throw", false)
        } catch let error as SpotifyConnectAPIError {
            check.equal("Connect failures keep status", error, .requestFailed(502))
            check.equal(
                "Connect failures use a stable category",
                error.errorDescription ?? "",
                "Spotify rejected the command (HTTP 502)"
            )
            omitSentinel("Connect LocalizedError", error.errorDescription)
        } catch {
            check.check("Connect command failures throw SpotifyConnectAPIError", false)
        }

        let queue = SpotifyWebPlayerAPI(
            accessToken: { "fixture-access" },
            transport: { request in
                (
                    Data("{\"error\":\"\(privacySentinel)\"}".utf8),
                    httpResponse(url: request.url ?? SpotifyWebPlayerAPI.queueURL, status: 429)
                )
            }
        )
        do {
            _ = try await queue.queue()
            check.check("queue Web API failures throw", false)
        } catch let error as SpotifyWebPlayerAPIError {
            check.equal("queue failures keep status", error, .requestFailed(429))
            check.equal("queue status remains readable for cooldown", error.statusCode ?? -1, 429)
            check.equal(
                "queue failures use a stable category",
                error.errorDescription ?? "",
                "Spotify rejected the queue request (HTTP 429)"
            )
            omitSentinel("queue LocalizedError", error.errorDescription)
        } catch {
            check.check("queue Web API failures throw SpotifyWebPlayerAPIError", false)
        }

        let forbiddenQueue = SpotifyWebPlayerAPI(
            accessToken: { "fixture-access" },
            transport: { request in
                (
                    Data(privacySentinel.utf8),
                    httpResponse(url: request.url ?? SpotifyWebPlayerAPI.queueURL, status: 403)
                )
            }
        )
        do {
            _ = try await forbiddenQueue.queue()
            check.check("forbidden queue failures throw", false)
        } catch let error as SpotifyWebPlayerAPIError {
            check.equal("401/403 capability still reads status", error.statusCode ?? -1, 403)
            omitSentinel("forbidden queue LocalizedError", error.errorDescription)
        } catch {
            check.check("forbidden queue failures throw SpotifyWebPlayerAPIError", false)
        }

        let attributes = TrackAttributesAPI(
            accessToken: { "fixture-access" },
            clientToken: { "fixture-client" },
            invalidateClientToken: { _ in },
            transport: { request in
                (
                    Data(privacySentinel.utf8),
                    httpResponse(url: request.url ?? TrackAttributesAPI.endpoint, status: 500)
                )
            }
        )
        do {
            _ = try await attributes.attributes(for: ["spotify:track:6rqhFgbbKwnb9MLmUQDhG6"])
            check.check("track-attribute failures throw", false)
        } catch let error as TrackAttributesAPIError {
            check.equal("attribute failures keep status", error, .requestFailed(500))
            check.equal(
                "attribute failures use a stable category",
                error.errorDescription ?? "",
                "Spotify rejected the attribute request (HTTP 500)"
            )
            omitSentinel("track-attribute LocalizedError", error.errorDescription)
        } catch {
            check.check("track-attribute failures throw TrackAttributesAPIError", false)
        }

        let failedPhase = PlaybackSessionPhase.failed(
            PartnerAPIError.requestFailed(503).errorDescription ?? privacySentinel
        )
        check.equal("failed session phases log a stable category", failedPhase.diagnosticLabel, "failed")
        omitSentinel("session diagnosticLabel", failedPhase.diagnosticLabel)
        let publicLog = "Session phase changed: ready -> \(failedPhase.diagnosticLabel); epoch=8"
        omitSentinel("public session phase log", publicLog)
        check.check("session phase logs keep epoch", publicLog.contains("epoch=8"))
    }
}
