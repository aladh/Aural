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
        let parsed = LoopbackRequestParser.parseRequestLine("GET /login?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\n")
        check.notNil("GET line parses", parsed)
        check.equal("path", parsed?.path, "/login")
        check.equal("code parameter", parsed?.queryItems?.first(where: { $0.name == "code" })?.value, "abc")
        check.equal("state parameter", parsed?.queryItems?.first(where: { $0.name == "state" })?.value, "xyz")

        let splitLine = LoopbackRequestParser.parseRequestLine("GET /login?code=abc HTTP/1.1")
        check.notNil("split request still parses", splitLine)
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
    }

    check.suite("Spotify uri parsing") {
        check.equal("kind-matched playlist uri yields its id", SpotifyURI.id(from: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M", kind: "playlist"), "37i9dQZF1DXcBWIGoYBM5M")
        check.nil_("folder uris never pass as playlists", SpotifyURI.id(from: "spotify:user:alice:folder:9ab01c", kind: "playlist"))
        check.nil_("a mismatched kind is refused", SpotifyURI.id(from: "spotify:album:abc123", kind: "playlist"))
        check.equal("kind-free parsing takes the last component", SpotifyURI.id(from: "spotify:user:alice:playlist:xyz789"), "xyz789")
    }
}
