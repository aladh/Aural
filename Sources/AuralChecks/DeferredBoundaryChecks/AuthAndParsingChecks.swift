//
//  AuthAndParsingChecks.swift
//  Aural
//

import Foundation
@testable import AuralCore


@MainActor
func runAuthFlowChecks(_ check: CheckRunner) {
    check.suite("Token response parsing") {
        let body = Data("""
        {"access_token":"at","refresh_token":"rt","expires_in":3600,"username":"listener"}
        """.utf8)
        let now = Date(timeIntervalSince1970: 1_000_000)

        let tokens = try? KeymasterAuth.parseTokenResponse(body, fallbackRefreshToken: nil, now: now)
        check.notNil("well-formed response parses", tokens)
        if let tokens {
            check.equal("access token", tokens.accessToken, "at")
            check.equal("refresh token", tokens.refreshToken, "rt")
            check.equal("username", tokens.username, "listener")
            check.equal("expiry resolves against the injected clock", tokens.expiresAt, now.addingTimeInterval(3_600))
        }

        // A refresh that omits its token must keep the previous one alive.
        let rotated = try? KeymasterAuth.parseTokenResponse(
            Data(#"{"access_token":"at2","expires_in":1800}"#.utf8),
            fallbackRefreshToken: "previous-rt",
            now: now
        )
        check.equal("rotation without a new token keeps the old one", rotated?.refreshToken, "previous-rt")

        for malformed in [Data("{}".utf8), Data(#"{"refresh_token":"rt"}"#.utf8)] {
            var threw = false
            do {
                _ = try KeymasterAuth.parseTokenResponse(malformed, fallbackRefreshToken: nil, now: now)
            } catch {
                threw = (error as? KeymasterAuthError) == .malformedTokenResponse
            }
            check.check("response without an access token is malformed", threw)
        }

        // A wrongly-typed access token must fail closed rather than mint an empty credential.
        var wrongType = false
        do {
            _ = try KeymasterAuth.parseTokenResponse(
                Data(#"{"access_token":123,"expires_in":3600}"#.utf8),
                fallbackRefreshToken: nil,
                now: now
            )
        } catch {
            wrongType = (error as? KeymasterAuthError) == .malformedTokenResponse
        }
        check.check("numeric access token is malformed", wrongType)

        // An unreadable expiry falls back to the standard hour instead of expiring instantly.
        let stringExpiry = try? KeymasterAuth.parseTokenResponse(
            Data(#"{"access_token":"at","refresh_token":"rt","expires_in":"3600"}"#.utf8),
            fallbackRefreshToken: nil,
            now: now
        )
        check.equal(
            "string expires_in falls back to the default hour",
            stringExpiry?.expiresAt,
            now.addingTimeInterval(3_600)
        )

        // An omitted expiry behaves the same way.
        let missingExpiry = try? KeymasterAuth.parseTokenResponse(
            Data(#"{"access_token":"at","refresh_token":"rt"}"#.utf8),
            fallbackRefreshToken: nil,
            now: now
        )
        check.equal(
            "missing expires_in defaults to one hour",
            missingExpiry?.expiresAt,
            now.addingTimeInterval(3_600)
        )
    }

    check.suite("Refresh failure classification") {
        let revoked = KeymasterAuth.tokenFailure(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
        check.equal("only invalid_grant revokes the grant", revoked == .grantRevoked, true)

        var classifiedAsFailure = false
        if case .tokenExchangeFailed = KeymasterAuth.tokenFailure(
            status: 400,
            body: Data(#"{"error":"invalid_request"}"#.utf8)
        ) { classifiedAsFailure = true }
        check.check("a non-revocation refusal keeps the grant", classifiedAsFailure)

        var serverErrorKeepsGrant = false
        if case .tokenExchangeFailed = KeymasterAuth.tokenFailure(status: 500, body: Data()) {
            serverErrorKeepsGrant = true
        }
        check.check("server errors are transient", serverErrorKeepsGrant)
    }

    check.suite("Redirect validation") {
        func code(from query: String, state: String) throws -> String {
            let callback = URLComponents(string: "http://127.0.0.1/login?\(query)")!
            return try KeymasterAuth.authorizationCode(from: callback, expectedState: state)
        }

        check.noThrow("matching state yields the code") {
            let value = try code(from: "code=abc&state=expected", state: "expected")
            check.equal("authorization code extracted", value, "abc")
        }

        // A forged or stale redirect must fail on state even when it carries an error
        // that would otherwise read as a user cancellation.
        var mismatched = false
        do {
            _ = try code(from: "error=access_denied&state=wrong", state: "expected")
        } catch {
            mismatched = (error as? KeymasterAuthError) == .stateMismatch
        }
        check.check("state is checked before error and code", mismatched)

        var denied = false
        do {
            _ = try code(from: "error=access_denied&state=expected", state: "expected")
        } catch {
            denied = (error as? KeymasterAuthError) == .authorizationDenied("access_denied")
        }
        check.check("user denial is reported as such", denied)

        var missingCode = false
        do {
            _ = try code(from: "state=expected", state: "expected")
        } catch {
            missingCode = (error as? KeymasterAuthError) == .noAuthorizationCode
        }
        check.check("missing code is reported as such", missingCode)

        let url = KeymasterAuth.authorizationURL(port: 49_152, challenge: "challenge", state: "state")
        check.notNil("authorization URL builds", url)
        if let url,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        {
            check.equal("PKCE method", items.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
            check.equal(
                "loopback redirect names the listening port",
                items.first(where: { $0.name == "redirect_uri" })?.value,
                "http://127.0.0.1:49152/login"
            )
            check.check(
                "streaming scope requested",
                items.first(where: { $0.name == "scope" })?.value?.contains("streaming") == true
            )
        }

        // RFC 7636 Appendix B.
        check.equal(
            "PKCE challenge matches the RFC reference vector",
            PKCE.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }
}

@MainActor
func runPaginationChecks(_ check: CheckRunner) {
    check.suite("Library pagination arithmetic") {
        // Walks advance by what each page carried, not by how many rows decoded.
        check.equal(
            "mid-collection page advances by its entry count",
            Pagination.nextOffset(offset: 50, pageEntryCount: 50, totalCount: 130),
            100
        )
        check.nil_("reaching totalCount ends the walk", Pagination.nextOffset(offset: 100, pageEntryCount: 30, totalCount: 130))
        check.nil_("overshooting totalCount ends the walk", Pagination.nextOffset(offset: 100, pageEntryCount: 50, totalCount: 130))

        // A collection that shrinks mid-walk would otherwise name a length no offset reaches.
        check.nil_("an empty page ends the walk", Pagination.nextOffset(offset: 50, pageEntryCount: 0, totalCount: 130))

        // A missing totalCount keeps walking until a page comes back empty.
        check.equal(
            "missing totalCount keeps walking",
            Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: nil),
            50
        )

        // Folders decode as entries but can collapse the rendered list; the offset must
        // still move by the raw count or pages would repeat.
        check.equal(
            "offset ignores how many entities survived decoding",
            Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: 60),
            50
        )

        // The last row before the boundary still names a next page; only reaching the
        // total ends the walk.
        check.equal(
            "one short of totalCount keeps walking",
            Pagination.nextOffset(offset: 100, pageEntryCount: 29, totalCount: 130),
            129
        )

        // A collection served in a single page must not ask for another.
        check.nil_(
            "single-page collections end immediately",
            Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: 50)
        )

        // A collection that empties mid-walk names no further offset either.
        check.nil_(
            "an emptied collection ends the walk",
            Pagination.nextOffset(offset: 40, pageEntryCount: 20, totalCount: 0)
        )
    }
}

@MainActor
func runLoopbackParsingChecks(_ check: CheckRunner) {
    check.suite("Loopback request-line parsing") {
        let parsed = LoopbackCallbackServer.parseRequestLine(
            "GET /login?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\n"
        )
        check.notNil("GET line parses", parsed)
        if let parsed {
            check.equal("path", parsed.path, "/login")
            check.equal("code parameter", parsed.queryItems?.first(where: { $0.name == "code" })?.value, "abc")
            check.equal("state parameter", parsed.queryItems?.first(where: { $0.name == "state" })?.value, "xyz")
        }

        // A request split across TCP reads may arrive with no trailing newline yet.
        let splitLine = LoopbackCallbackServer.parseRequestLine("GET /login?code=abc HTTP/1.1")
        check.notNil("split request still parses", splitLine)
        if let splitLine {
            check.equal("split-request path", splitLine.path, "/login")
            check.equal("split-request code", splitLine.queryItems?.first(where: { $0.name == "code" })?.value, "abc")
        }

        check.nil_("empty input rejected", LoopbackCallbackServer.parseRequestLine(""))
        check.nil_("newline-only input rejected", LoopbackCallbackServer.parseRequestLine("\n"))
        check.nil_(
            "non-GET methods rejected",
            LoopbackCallbackServer.parseRequestLine("POST /login?code=abc HTTP/1.1\n")
        )
        // HTTP verbs are case-sensitive; a smuggled lowercase one is not our request.
        check.nil_(
            "lowercase methods rejected",
            LoopbackCallbackServer.parseRequestLine("get /login?code=abc HTTP/1.1\n")
        )

        // A query-less line still parses: the code simply comes back absent.
        let bare = LoopbackCallbackServer.parseRequestLine("GET /login HTTP/1.1\n")
        check.notNil("query-less request parses", bare)
        if let bare {
            check.equal("query-less path", bare.path, "/login")
            check.nil_("no parameters without a query", bare.queryItems)
        }
    }
}

@MainActor
func runURIChecks(_ check: CheckRunner) {
    check.suite("Spotify uri parsing") {
        check.equal(
            "kind-matched playlist uri yields its id",
            SpotifyURI.id(from: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M", kind: "playlist"),
            "37i9dQZF1DXcBWIGoYBM5M"
        )

        // A playlist folder wears an id at the end too; requiring the kind is what
        // keeps it from masquerading as a playlist.
        check.nil_(
            "folder uris never pass as playlists",
            SpotifyURI.id(from: "spotify:user:alice:folder:9ab01c", kind: "playlist")
        )
        check.nil_(
            "a mismatched kind is refused",
            SpotifyURI.id(from: "spotify:album:abc123", kind: "playlist")
        )
        check.equal(
            "kind-free parsing takes the last component",
            SpotifyURI.id(from: "spotify:user:alice:playlist:xyz789"),
            "xyz789"
        )
    }
}
