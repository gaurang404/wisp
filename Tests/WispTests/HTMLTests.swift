import XCTest
@testable import Wisp

final class HTMLTests: XCTestCase {
    private func response(_ html: String, status: Int = 200, type: String = "text/html; charset=utf-8",
                          url: String = "https://example.com/", redirects: [Redirect] = []) -> ResponseData {
        ResponseData(status: status, headers: [("Content-Type", type)], body: Data(html.utf8), duration: 0.1,
                     url: URL(string: url), prettyJSON: nil, text: html, redirects: redirects)
    }

    func testSummary() {
        let html = """
        <!doctype html><html><head><title>Acme &amp; Co</title>
        <meta content="Fast &quot;APIs&quot;" name="description">
        <meta http-equiv="refresh" content="0;url='/login'">
        <style>.x{}</style><script>var secret = 1</script></head>
        <body><h1>Welcome</h1><p>Hello&nbsp;world &#169; &#x2014;</p>
        <a href="/docs">Docs</a><a href="https://x.io/a">A</a><a href="/docs">Docs again</a><a href="#top">Top</a>
        <form><input type="password" name="p"></form></body></html>
        """
        let s = HTMLSummary.parse(html, base: URL(string: "https://example.com/start"))
        XCTAssertEqual(s.title, "Acme & Co")
        XCTAssertEqual(s.description, "Fast \"APIs\"")
        XCTAssertEqual(s.metaRefresh?.absoluteString, "https://example.com/login")
        XCTAssertTrue(s.hasPasswordField)
        XCTAssertEqual(s.headings, ["Welcome"])
        XCTAssertEqual(s.links.map(\.url.absoluteString), ["https://example.com/docs", "https://x.io/a"])
        XCTAssertTrue(s.text.contains("Hello world © —"))
        XCTAssertFalse(s.text.contains("secret"))
    }

    func testDetectionAndSniffing() {
        XCTAssertTrue(response("<p>x</p>").isHTML)
        XCTAssertTrue(response("  <!DOCTYPE html><html></html>", type: "text/plain").isHTML)
        XCTAssertFalse(response("{\"a\":1}", type: "application/json").isHTML)
    }

    func testHints() {
        let redirected = response("<html><title>Docs</title></html>", url: "https://developers.mailerlite.com/",
                                  redirects: [Redirect(status: 302, from: URL(string: "https://connect.mailerlite.com/")!,
                                                       to: URL(string: "https://developers.mailerlite.com")!)])
        var h = HTMLHint.make(for: redirected, summary: HTMLSummary.parse(redirected.text, base: redirected.url),
                              knownBase: "https://connect.mailerlite.com/api")
        XCTAssertEqual(h.title, "Redirected to developers.mailerlite.com")
        XCTAssertTrue(h.detail.contains("https://connect.mailerlite.com/api"))

        h = HTMLHint.make(for: redirected, summary: HTMLSummary.parse(redirected.text, base: redirected.url), knownBase: nil)
        XCTAssertTrue(h.detail.contains("/api or /v1"))

        let login = response("<form><input type=password></form>", status: 401)
        h = HTMLHint.make(for: login, summary: HTMLSummary.parse(login.text, base: nil), knownBase: nil)
        XCTAssertEqual(h.title, "Looks like a sign-in page")

        let moved = response(#"<meta http-equiv="refresh" content="0;url='../'">"#, url: "https://site.io/demo/v0/")
        h = HTMLHint.make(for: moved, summary: HTMLSummary.parse(moved.text, base: moved.url), knownBase: nil)
        XCTAssertEqual(h.title, "This page redirects to /demo/")

        let gateway = response("<h1>502 Bad Gateway</h1>", status: 502)
        h = HTMLHint.make(for: gateway, summary: HTMLSummary.parse(gateway.text, base: nil), knownBase: nil)
        XCTAssertEqual(h.title, "Server error page")
    }
}
