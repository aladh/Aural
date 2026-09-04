import Testing
//
//  AuthAndParsingChecks.swift
//  Spotty
//

import Foundation
@testable import SpottyCore

@Suite("Auth Flow")
struct AuthFlowTests {
    @Test
    @MainActor
    func testAuthFlow() {
        do {
            let body = Data(
                """
                {"access_token":"at","refresh_token":"rt","expires_in":3600,"username":"listener"}
                """.utf8)
            let now = Date(timeIntervalSince1970: 1_000_000)

            let tokens = try? KeymasterAuth.parseTokenResponse(body, fallbackRefreshToken: nil, now: now)
            #expect((tokens) != nil, "well-formed response parses")
            if let tokens {
                #expect((tokens.accessToken) == ("at"), "access token")
                #expect((tokens.refreshToken) == ("rt"), "refresh token")
                #expect((tokens.username) == ("listener"), "username")
                #expect(
                    (tokens.expiresAt) == (now.addingTimeInterval(3_600)), "expiry resolves against the injected clock")
            }

            // A refresh that omits its token must keep the previous one alive.
            let rotated = try? KeymasterAuth.parseTokenResponse(
                Data(#"{"access_token":"at2","expires_in":1800}"#.utf8),
                fallbackRefreshToken: "previous-rt",
                now: now
            )
            #expect((rotated?.refreshToken) == ("previous-rt"), "rotation without a new token keeps the old one")

            for malformed in [Data("{}".utf8), Data(#"{"refresh_token":"rt"}"#.utf8)] {
                var threw = false
                do {
                    _ = try KeymasterAuth.parseTokenResponse(malformed, fallbackRefreshToken: nil, now: now)
                } catch {
                    threw = (error as? KeymasterAuthError) == .malformedTokenResponse
                }
                #expect((threw) == true, "response without an access token is malformed")
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
            #expect((wrongType) == true, "numeric access token is malformed")

            // An unreadable expiry falls back to the standard hour instead of expiring instantly.
            let stringExpiry = try? KeymasterAuth.parseTokenResponse(
                Data(#"{"access_token":"at","refresh_token":"rt","expires_in":"3600"}"#.utf8),
                fallbackRefreshToken: nil,
                now: now
            )
            #expect(
                (stringExpiry?.expiresAt) == (now.addingTimeInterval(3_600)),
                "string expires_in falls back to the default hour")

            // An omitted expiry behaves the same way.
            let missingExpiry = try? KeymasterAuth.parseTokenResponse(
                Data(#"{"access_token":"at","refresh_token":"rt"}"#.utf8),
                fallbackRefreshToken: nil,
                now: now
            )
            #expect(
                (missingExpiry?.expiresAt) == (now.addingTimeInterval(3_600)), "missing expires_in defaults to one hour"
            )
        }

        do {
            let revoked = KeymasterAuth.tokenFailure(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
            #expect((revoked == .grantRevoked) == (true), "only invalid_grant revokes the grant")

            var classifiedAsFailure = false
            if case .tokenExchangeFailed = KeymasterAuth.tokenFailure(
                status: 400,
                body: Data(#"{"error":"invalid_request"}"#.utf8)
            ) {
                classifiedAsFailure = true
            }
            #expect((classifiedAsFailure) == true, "a non-revocation refusal keeps the grant")

            var serverErrorKeepsGrant = false
            if case .tokenExchangeFailed = KeymasterAuth.tokenFailure(status: 500, body: Data()) {
                serverErrorKeepsGrant = true
            }
            #expect((serverErrorKeepsGrant) == true, "server errors are transient")

            let sentinel = "SPOTTY_PRIVACY_SENTINEL_token-body_7f3c"
            let refused = KeymasterAuth.tokenFailure(
                status: 400,
                body: Data(#"{"error":"invalid_request","error_description":"\#(sentinel)"}"#.utf8)
            )
            #expect((refused) == (.tokenExchangeFailed(400)), "non-revocation token failures keep HTTP status")
            #expect(
                (refused.errorDescription ?? "") == ("Token exchange failed (HTTP 400)"),
                "token failures surface a stable HTTP category")
            #expect(
                (refused.errorDescription?.contains(sentinel) == false) == true,
                "token failure descriptions omit the response body")
        }

        do {
            func code(from query: String, state: String) throws -> String {
                let callback = URLComponents(string: "http://127.0.0.1/login?\(query)")!
                return try KeymasterAuth.authorizationCode(from: callback, expectedState: state)
            }

            do {
                do {
                    let value = try code(from: "code=abc&state=expected", state: "expected")
                    #expect((value) == ("abc"), "authorization code extracted")

                } catch {
                    Issue.record("\("matching state yields the code"): unexpected error \(error)")
                }
            }

            // A forged or stale redirect must fail on state even when it carries an error
            // that would otherwise read as a user cancellation.
            var mismatched = false
            do {
                _ = try code(from: "error=access_denied&state=wrong", state: "expected")
            } catch {
                mismatched = (error as? KeymasterAuthError) == .stateMismatch
            }
            #expect((mismatched) == true, "state is checked before error and code")

            var denied = false
            do {
                _ = try code(from: "error=access_denied&state=expected", state: "expected")
            } catch {
                denied = (error as? KeymasterAuthError) == .authorizationDenied
            }
            #expect((denied) == true, "user denial is reported as such")

            let deniedSentinel = "SPOTTY_PRIVACY_SENTINEL_oauth-error_4c1a"
            var deniedDescription: String?
            do {
                _ = try code(from: "error=\(deniedSentinel)&state=expected", state: "expected")
                #expect((false) == true, "authorization denial with sentinel text throws")
            } catch let error as LocalizedError {
                deniedDescription = error.errorDescription
            } catch {
                #expect((false) == true, "authorization denial with sentinel text is LocalizedError, got \(error)")
            }
            #expect(
                (deniedDescription ?? "") == ("Spotify declined the authorization"),
                "authorization denial uses a stable category")
            #expect(
                (deniedDescription?.contains(deniedSentinel) == false) == true,
                "authorization denial omits redirect error text")

            var missingCode = false
            do {
                _ = try code(from: "state=expected", state: "expected")
            } catch {
                missingCode = (error as? KeymasterAuthError) == .noAuthorizationCode
            }
            #expect((missingCode) == true, "missing code is reported as such")

            let url = KeymasterAuth.authorizationURL(port: 49_152, challenge: "challenge", state: "state")
            #expect((url) != nil, "authorization URL builds")
            if let url,
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            {
                #expect((items.first(where: { $0.name == "code_challenge_method" })?.value) == ("S256"), "PKCE method")
                #expect(
                    (items.first(where: { $0.name == "redirect_uri" })?.value) == ("http://127.0.0.1:49152/login"),
                    "loopback redirect names the listening port")
                #expect(
                    (items.first(where: { $0.name == "scope" })?.value?.contains("streaming") == true) == true,
                    "streaming scope requested")
            }

            // RFC 7636 Appendix B.
            #expect(
                (PKCE.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
                    == ("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"),
                "PKCE challenge matches the RFC reference vector")
        }
    }
}

@Suite("Pagination")
struct PaginationTests {
    @Test
    @MainActor
    func testPagination() {
        do {
            // Walks advance by what each page carried, not by how many rows decoded.
            #expect(
                (Pagination.nextOffset(offset: 50, pageEntryCount: 50, totalCount: 130)) == (100),
                "mid-collection page advances by its entry count")
            #expect(
                (Pagination.nextOffset(offset: 100, pageEntryCount: 30, totalCount: 130)) == nil,
                "reaching totalCount ends the walk")
            #expect(
                (Pagination.nextOffset(offset: 100, pageEntryCount: 50, totalCount: 130)) == nil,
                "overshooting totalCount ends the walk")

            // A collection that shrinks mid-walk would otherwise name a length no offset reaches.
            #expect(
                (Pagination.nextOffset(offset: 50, pageEntryCount: 0, totalCount: 130)) == nil,
                "an empty page ends the walk")

            // A missing totalCount keeps walking until a page comes back empty.
            #expect(
                (Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: nil)) == (50),
                "missing totalCount keeps walking")

            // Folders decode as entries but can collapse the rendered list; the offset must
            // still move by the raw count or pages would repeat.
            #expect(
                (Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: 60)) == (50),
                "offset ignores how many entities survived decoding")

            // The last row before the boundary still names a next page; only reaching the
            // total ends the walk.
            #expect(
                (Pagination.nextOffset(offset: 100, pageEntryCount: 29, totalCount: 130)) == (129),
                "one short of totalCount keeps walking")

            // A collection served in a single page must not ask for another.
            #expect(
                (Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: 50)) == nil,
                "single-page collections end immediately")

            // A collection that empties mid-walk names no further offset either.
            #expect(
                (Pagination.nextOffset(offset: 40, pageEntryCount: 20, totalCount: 0)) == nil,
                "an emptied collection ends the walk")
        }
    }
}

@Suite("Loopback Parsing")
struct LoopbackParsingTests {
    @Test
    @MainActor
    func testLoopbackParsing() {
        do {
            let parsed = LoopbackCallbackServer.parseRequestLine(
                "GET /login?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\n"
            )
            #expect((parsed) != nil, "CRLF GET line parses")
            if let parsed {
                #expect((parsed.path) == ("/login"), "path")
                #expect((parsed.queryItems?.first(where: { $0.name == "code" })?.value) == ("abc"), "code parameter")
                #expect((parsed.queryItems?.first(where: { $0.name == "state" })?.value) == ("xyz"), "state parameter")
            }

            let lf = LoopbackCallbackServer.parseRequestLine(
                "GET /login?code=abc&state=xyz HTTP/1.1\nHost: 127.0.0.1\n"
            )
            #expect((lf?.path) == ("/login"), "LF terminator yields the same path")

            // A request split across TCP reads may arrive with no trailing newline yet.
            let splitLine = LoopbackCallbackServer.parseRequestLine("GET /login?code=abc HTTP/1.1")
            #expect((splitLine) != nil, "split request still parses")
            if let splitLine {
                #expect((splitLine.path) == ("/login"), "split-request path")
                #expect(
                    (splitLine.queryItems?.first(where: { $0.name == "code" })?.value) == ("abc"), "split-request code")
            }

            #expect((LoopbackCallbackServer.parseRequestLine("")) == nil, "empty input rejected")
            #expect((LoopbackCallbackServer.parseRequestLine("\n")) == nil, "newline-only input rejected")
            #expect(
                (LoopbackCallbackServer.parseRequestLine("POST /login?code=abc HTTP/1.1\n")) == nil,
                "non-GET methods rejected")
            // HTTP verbs are case-sensitive; a smuggled lowercase one is not our request.
            #expect(
                (LoopbackCallbackServer.parseRequestLine("get /login?code=abc HTTP/1.1\n")) == nil,
                "lowercase methods rejected")

            // A query-less line still parses: the code simply comes back absent.
            let bare = LoopbackCallbackServer.parseRequestLine("GET /login HTTP/1.1\n")
            #expect((bare) != nil, "query-less request parses")
            if let bare {
                #expect((bare.path) == ("/login"), "query-less path")
                #expect((bare.queryItems) == nil, "no parameters without a query")
            }

            #expect((LoopbackCallbackServer.parseRequestLine("GET / HTTP/1.1\n")) == nil, "root path rejected")
            #expect(
                (LoopbackCallbackServer.parseRequestLine("GET /?code=abc&state=xyz HTTP/1.1\n")) == nil,
                "root path with query cannot win")
            #expect(
                (LoopbackCallbackServer.parseRequestLine("GET /login/extra?code=abc HTTP/1.1\n")) == nil,
                "prefix lookalike rejected")
            #expect(
                (LoopbackCallbackServer.parseRequestLine("GET /loginn?code=abc HTTP/1.1\n")) == nil,
                "suffix lookalike rejected")
            #expect(
                (LoopbackCallbackServer.parseRequestLine("GET /login%2Fextra?code=abc HTTP/1.1\n")) == nil,
                "encoded extra segment rejected")
            #expect(
                (LoopbackCallbackServer.parseRequestLine("GET /login?code=abc HTTP/\n")) == nil,
                "empty HTTP version rejected")
            #expect(
                (LoopbackCallbackServer.parseRequestLine("GET /login?code=abc HTTP/1.1junk\n")) == nil,
                "suffixed HTTP version rejected")
        }
    }
}

@Suite("Loopback Server")
struct LoopbackServerTests {
    @Test
    @MainActor
    func testLoopbackServer() async {
        do {
            let server = LoopbackCallbackServer()
            let port: UInt16
            do {
                port = try await server.start()
            } catch {
                #expect((false) == true, "loopback listener starts")
                return
            }

            let session = URLSession(configuration: .ephemeral)
            async let callback = server.waitForCallback(timeout: .seconds(5))

            let rejectedRoot = await httpStatus(session: session, url: URL(string: "http://127.0.0.1:\(port)/")!)
            #expect((rejectedRoot) == (404), "GET / is not found")
            let rejectedLookalike = await httpStatus(
                session: session,
                url: URL(string: "http://127.0.0.1:\(port)/login/extra?code=steal&state=steal")!
            )
            #expect((rejectedLookalike) == (404), "GET /login/extra is not found")

            let accepted = await httpStatus(
                session: session,
                url: URL(string: "http://127.0.0.1:\(port)/login?code=ok&state=s")!
            )
            #expect((accepted) == (200), "GET /login is accepted")

            do {
                let components = try await callback
                #expect((components.path) == ("/login"), "accepted target is /login")
                #expect(
                    (components.queryItems?.first(where: { $0.name == "code" })?.value) == ("ok"),
                    "code survives rejected predecessors")
            } catch {
                #expect((false) == true, "rejected targets do not finish the waiter")
            }
        }
    }
}

private func httpStatus(session: URLSession, url: URL) async -> Int {
    do {
        let (_, response) = try await session.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    } catch {
        return -1
    }
}

@Suite("Auth Cookie Cleanup")
struct AuthCookieCleanupTests {
    @Test
    @MainActor
    func testAuthCookieCleanup() async {
        do {
            func cookie(_ name: String, domain: String, path: String = "/") -> HTTPCookie {
                HTTPCookie(properties: [
                    .name: name,
                    .value: "token",
                    .domain: domain,
                    .path: path,
                ])!
            }

            let spotify = cookie("sp_dc", domain: "accounts.spotify.com")
            let apex = cookie("sp_key", domain: "spotify.com")
            let lookalike = cookie("sp_dc", domain: "notspotify.com")
            let unrelated = cookie("sid", domain: "example.com")
            let deleted = AuthCookieCleanup.cookiesToDelete(in: [unrelated, lookalike, apex, spotify])
            #expect((Set(deleted.map(\.name))) == (Set(["sp_dc", "sp_key"])), "only Spotify cookies are selected")
            #expect(
                (AuthCookieCleanup.cookiesToDelete(in: [unrelated, lookalike]).map(\.name)) == ([]),
                "a second selection of the remainder is empty")
            #expect(
                (AuthCookieCleanup.cookiesToDelete(in: deleted).map(\.name)) == (deleted.map(\.name)),
                "selection is idempotent")
        }

        do {
            let store = MemoryKeymasterStore()
            let counter = CleanupCounter()
            let session = KeymasterSession(
                store: store,
                refresher: { _ in throw KeymasterAuthError.grantRevoked },
                cookieCleanup: { counter.increment() }
            )
            let tokens = KeymasterTokens(
                accessToken: "at",
                refreshToken: "rt",
                expiresAt: Date().addingTimeInterval(3_600),
                username: "listener"
            )
            do {
                try await session.adopt(tokens)
                #expect((true) == true, "adopt writes the grant")
            } catch {
                #expect((false) == true, "adopt writes the grant")
            }
            await session.clear()
            #expect((counter.count) == (1), "clearing the grant removes Spotify cookies")
            await session.clear()
            #expect((counter.count) == (2), "a second clear is still safe")
            #expect((store.stored) == nil, "the grant does not return after cookie cleanup")
        }
    }
}

private final class MemoryKeymasterStore: KeymasterTokenStoring, @unchecked Sendable {
    var stored: KeymasterTokens?

    func loadResult() -> KeymasterGrantLoadResult {
        stored.map(KeymasterGrantLoadResult.found) ?? .absent
    }

    func save(_ tokens: KeymasterTokens) throws {
        stored = tokens
    }

    func clear() {
        stored = nil
    }
}

private final class CleanupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("URI")
struct URITests {
    @Test
    @MainActor
    func testURI() {
        do {
            #expect(
                (SpotifyURI.id(from: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M", kind: "playlist"))
                    == ("37i9dQZF1DXcBWIGoYBM5M"), "kind-matched playlist uri yields its id")

            // A playlist folder wears an id at the end too; requiring the kind is what
            // keeps it from masquerading as a playlist.
            #expect(
                (SpotifyURI.id(from: "spotify:user:alice:folder:9ab01c", kind: "playlist")) == nil,
                "folder uris never pass as playlists")
            #expect(
                (SpotifyURI.id(from: "spotify:album:abc123", kind: "playlist")) == nil, "a mismatched kind is refused")
            #expect(
                (SpotifyURI.id(from: "spotify:user:alice:playlist:xyz789")) == ("xyz789"),
                "kind-free parsing takes the last component")
        }
    }
}
