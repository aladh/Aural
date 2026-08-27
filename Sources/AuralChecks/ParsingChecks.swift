import AuralDomain
import Foundation

func runParsingChecks(_ check: CheckRunner) {
    check.suite("Library pagination arithmetic") {
        check.equal("mid-collection page advances by its entry count", Pagination.nextOffset(offset: 50, pageEntryCount: 50, totalCount: 130), 100)
        check.nil_("reaching totalCount ends the walk", Pagination.nextOffset(offset: 100, pageEntryCount: 30, totalCount: 130))
        check.nil_("overshooting totalCount ends the walk", Pagination.nextOffset(offset: 100, pageEntryCount: 50, totalCount: 130))
        check.nil_("an empty page ends the walk", Pagination.nextOffset(offset: 50, pageEntryCount: 0, totalCount: 130))
        check.equal("missing totalCount keeps walking", Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: nil), 50)
        check.equal("offset ignores how many entities survived decoding", Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: 60), 50)
        check.equal("one short of totalCount keeps walking", Pagination.nextOffset(offset: 100, pageEntryCount: 29, totalCount: 130), 129)
        check.nil_("single-page collections end immediately", Pagination.nextOffset(offset: 0, pageEntryCount: 50, totalCount: 50))
        check.nil_("an emptied collection ends the walk", Pagination.nextOffset(offset: 40, pageEntryCount: 20, totalCount: 0))
    }

    check.suite("Loopback request-line parsing") {
        let crlf = LoopbackRequestParser.parseRequestLine("GET /login?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\n")
        check.notNil("CRLF GET line parses", crlf)
        check.equal("path", crlf?.path, "/login")
        check.equal("code parameter", crlf?.queryItems?.first(where: { $0.name == "code" })?.value, "abc")
        check.equal("state parameter", crlf?.queryItems?.first(where: { $0.name == "state" })?.value, "xyz")

        let lf = LoopbackRequestParser.parseRequestLine("GET /login?code=abc&state=xyz HTTP/1.1\nHost: 127.0.0.1\n")
        check.equal("LF terminator yields the same path", lf?.path, "/login")
        check.equal("LF terminator yields the same code", lf?.queryItems?.first(where: { $0.name == "code" })?.value, "abc")

        let splitLine = LoopbackRequestParser.parseRequestLine("GET /login?code=abc HTTP/1.1")
        check.notNil("unterminated split request still parses", splitLine)
        check.equal("split-request path", splitLine?.path, "/login")
        check.equal("split-request code", splitLine?.queryItems?.first(where: { $0.name == "code" })?.value, "abc")
        check.nil_("empty input rejected", LoopbackRequestParser.parseRequestLine(""))
        check.nil_("newline-only input rejected", LoopbackRequestParser.parseRequestLine("\n"))
        check.nil_("non-GET methods rejected", LoopbackRequestParser.parseRequestLine("POST /login?code=abc HTTP/1.1\n"))
        check.nil_("lowercase methods rejected", LoopbackRequestParser.parseRequestLine("get /login?code=abc HTTP/1.1\n"))
        let bare = LoopbackRequestParser.parseRequestLine("GET /login HTTP/1.1\n")
        check.notNil("query-less request parses", bare)
        check.equal("query-less path", bare?.path, "/login")
        check.nil_("no parameters without a query", bare?.queryItems)

        let encodedPath = LoopbackRequestParser.parseRequestLine("GET /%6Cogin?code=abc&state=xyz HTTP/1.1\n")
        check.equal("percent-decoded path is /login", encodedPath?.path, "/login")
        check.equal("percent-decoded path still yields the code", encodedPath?.queryItems?.first(where: { $0.name == "code" })?.value, "abc")

        let encodedQuery = LoopbackRequestParser.parseRequestLine("GET /login?code=a%20b&state=xy%26z HTTP/1.1\n")
        check.equal("query values stay percent-decoded", encodedQuery?.queryItems?.first(where: { $0.name == "code" })?.value, "a b")
        check.equal("encoded ampersands stay inside the value", encodedQuery?.queryItems?.first(where: { $0.name == "state" })?.value, "xy&z")

        check.nil_("root path rejected", LoopbackRequestParser.parseRequestLine("GET / HTTP/1.1\n"))
        check.nil_("root path with query cannot win", LoopbackRequestParser.parseRequestLine("GET /?code=abc&state=xyz HTTP/1.1\n"))
        check.nil_("prefix lookalike rejected", LoopbackRequestParser.parseRequestLine("GET /login/extra?code=abc HTTP/1.1\n"))
        check.nil_("suffix lookalike rejected", LoopbackRequestParser.parseRequestLine("GET /loginn?code=abc HTTP/1.1\n"))
        check.nil_("embedded /login rejected", LoopbackRequestParser.parseRequestLine("GET /callback/login?code=abc HTTP/1.1\n"))
        check.nil_("trailing slash rejected", LoopbackRequestParser.parseRequestLine("GET /login/?code=abc HTTP/1.1\n"))
        check.nil_("encoded extra segment rejected", LoopbackRequestParser.parseRequestLine("GET /login%2Fextra?code=abc HTTP/1.1\n"))
        check.nil_("double-slash target rejected", LoopbackRequestParser.parseRequestLine("GET //login?code=abc HTTP/1.1\n"))
        check.nil_("absolute-form target rejected", LoopbackRequestParser.parseRequestLine("GET http://127.0.0.1/login?code=abc HTTP/1.1\n"))
        check.nil_("missing HTTP version rejected", LoopbackRequestParser.parseRequestLine("GET /login?code=abc\n"))
        check.nil_("extra request-line tokens rejected", LoopbackRequestParser.parseRequestLine("GET /login HTTP/1.1 extra\n"))
        check.nil_("tab-separated request-line rejected", LoopbackRequestParser.parseRequestLine("GET\t/login HTTP/1.1\n"))
        check.notNil("HTTP/1.0 is accepted", LoopbackRequestParser.parseRequestLine("GET /login HTTP/1.0\n"))
        check.notNil("HTTP/2 is accepted", LoopbackRequestParser.parseRequestLine("GET /login HTTP/2\n"))
        check.nil_("empty HTTP version rejected", LoopbackRequestParser.parseRequestLine("GET /login?code=abc HTTP/\n"))
        check.nil_("suffixed HTTP version rejected", LoopbackRequestParser.parseRequestLine("GET /login?code=abc HTTP/1.1junk\n"))
        check.nil_("non-numeric HTTP version rejected", LoopbackRequestParser.parseRequestLine("GET /login?code=abc HTTP/not-a-version\n"))
    }

    check.suite("Spotify authentication cookie matching") {
        check.check("accounts host is Spotify", SpotifyAuthenticationCookies.shouldRemove(domain: "accounts.spotify.com", path: "/"))
        check.check("leading-dot domain is Spotify", SpotifyAuthenticationCookies.shouldRemove(domain: ".spotify.com", path: "/"))
        check.check("subdomain and subdirectory stay Spotify", SpotifyAuthenticationCookies.shouldRemove(domain: "www.spotify.com", path: "/api"))
        check.check("lookalike host is not Spotify", !SpotifyAuthenticationCookies.shouldRemove(domain: "notspotify.com", path: "/"))
        check.check("suffixed lookalike is not Spotify", !SpotifyAuthenticationCookies.shouldRemove(domain: "spotify.com.evil.example", path: "/"))
        check.check("unrelated domain is kept", !SpotifyAuthenticationCookies.shouldRemove(domain: "example.com", path: "/"))
        check.check("empty path is not a cookie path", !SpotifyAuthenticationCookies.shouldRemove(domain: "spotify.com", path: ""))
    }

    check.suite("Spotify uri parsing") {
        check.equal("kind-matched playlist uri yields its id", SpotifyURI.id(from: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M", kind: "playlist"), "37i9dQZF1DXcBWIGoYBM5M")
        check.nil_("folder uris never pass as playlists", SpotifyURI.id(from: "spotify:user:alice:folder:9ab01c", kind: "playlist"))
        check.nil_("a mismatched kind is refused", SpotifyURI.id(from: "spotify:album:abc123", kind: "playlist"))
        check.equal("kind-free parsing takes the last component", SpotifyURI.id(from: "spotify:user:alice:playlist:xyz789"), "xyz789")
    }
}
