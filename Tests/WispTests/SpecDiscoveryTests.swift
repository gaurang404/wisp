import XCTest
@testable import Wisp

final class SpecDiscoveryTests: XCTestCase {
    static let spec = #"""
    {"openapi":"3.0.3","info":{"title":"Pets","version":"1"},"servers":[{"url":"https://api.x.com"}],
     "paths":{"/pets":{"get":{"summary":"List pets","responses":{"200":{"description":"ok"}}}},
              "/pets/{id}":{"get":{"summary":"Get pet","parameters":[{"name":"id","in":"path","required":true,"schema":{"type":"string"}}],"responses":{"200":{"description":"ok"}}}}}}
    """#

    /// Fake server: URL string → (status, content-type, body). Missing URLs are 404s. Records every fetch.
    final class Fake {
        let routes: [String: (Int, String, String)]
        private var log: [String] = []
        private let lock = NSLock()
        var fetched: [String] { lock.withLock { log } }
        init(_ routes: [String: (Int, String, String)]) { self.routes = routes }
        var fetch: SpecDiscovery.Fetch {
            { [self] url in
                lock.withLock { log.append(url.absoluteString) }  // probes run concurrently
                let (status, type, body) = routes[url.absoluteString] ?? (404, "text/html", "<h1>Not found</h1>")
                let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
                return (Data(body.utf8), resp)
            }
        }
    }

    static func html(_ body: String) -> (Int, String, String) { (200, "text/html; charset=utf-8", "<!doctype html><html><head></head><body>\(body)</body></html>") }
    static let json = { (body: String) in (200, "application/json", body) }

    func testDirectSpecURL() async throws {
        let fake = Fake(["https://x.com/openapi.json": Self.json(Self.spec)])
        let f = try await SpecDiscovery.discover(URL(string: "https://x.com/openapi.json")!, fetch: fake.fetch)
        XCTAssertEqual(f.via, "the URL itself")
        XCTAssertEqual(f.result.format, "OpenAPI 3.0")
        XCTAssertEqual(f.result.requests.count, 2)
        XCTAssertEqual(fake.fetched.count, 1)
    }

    func testRedocRelativeSpecURL() async throws {
        let fake = Fake([
            "https://x.com/docs/": Self.html(#"<redoc spec-url="specs/api.yaml?v=2&amp;x=1"></redoc><script src="redoc.standalone.js"></script>"#),
            "https://x.com/docs/specs/api.yaml?v=2&x=1": (200, "application/yaml", "openapi: 3.1.0\ninfo:\n  title: Y\n  version: '1'\npaths:\n  /a:\n    get:\n      responses:\n        '200':\n          description: ok\n"),
        ])
        let f = try await SpecDiscovery.discover(URL(string: "https://x.com/docs/")!, fetch: fake.fetch)
        XCTAssertEqual(f.via, "Redoc spec-url")
        XCTAssertEqual(f.specURL.absoluteString, "https://x.com/docs/specs/api.yaml?v=2&x=1")
        XCTAssertEqual(f.result.format, "OpenAPI 3.1")
    }

    func testSwaggerUIInitializerScript() async throws {
        let fake = Fake([
            "https://x/docs/": Self.html(#"<div id="swagger-ui"></div><script src="./swagger-ui-bundle.js"></script><script src="./swagger-initializer.js" charset="UTF-8"></script>"#),
            "https://x/docs/swagger-initializer.js": (200, "application/javascript", """
                window.onload = function() {
                  window.ui = SwaggerUIBundle({
                    url: "https://x/api/v3/openapi.json",
                    dom_id: '#swagger-ui', validatorUrl: "https://validator.swagger.io/validator",
                    oauth2RedirectUrl: "https://x/docs/oauth2-redirect.html"
                  });
                };
                """),
            "https://x/api/v3/openapi.json": Self.json(Self.spec),
        ])
        let f = try await SpecDiscovery.discover(URL(string: "https://x/docs/")!, fetch: fake.fetch)
        XCTAssertEqual(f.via, "Swagger UI config")
        XCTAssertEqual(f.specURL.absoluteString, "https://x/api/v3/openapi.json")
        XCTAssertFalse(fake.fetched.contains("https://x/docs/swagger-ui-bundle.js"), "only initializer scripts are fetched")
    }

    func testSwaggerInitializerWithVariableURLPrefersSameHost() async throws {
        let fake = Fake([
            "https://pets.io/": Self.html(#"<script src="./swagger-initializer.js"></script>"#),
            "https://pets.io/swagger-initializer.js": (200, "text/javascript", """
                const def = "https://other.io/v2/swagger.json";
                const map = `pets.io=https://pets.io/api/v3/openapi.json,other.io=https://other.io/v2/swagger.json`;
                window.ui = SwaggerUIBundle({ url: pick(map, def), dom_id: "#ui" });
                """),
            "https://pets.io/api/v3/openapi.json": Self.json(Self.spec),
        ])
        let f = try await SpecDiscovery.discover(URL(string: "https://pets.io/")!, fetch: fake.fetch)
        XCTAssertEqual(f.specURL.absoluteString, "https://pets.io/api/v3/openapi.json")
        XCTAssertFalse(fake.fetched.contains("https://other.io/v2/swagger.json"))
    }

    func testSwaggerInlineURLsAndConfigURL() async throws {
        let inline = Fake([
            "https://x.com/": Self.html(##"<script>SwaggerUIBundle({ urls: [{name: "v1", url: "/v1/swagger.json"}], dom_id: "#ui" })</script>"##),
            "https://x.com/v1/swagger.json": Self.json(#"{"swagger":"2.0","info":{"title":"T"},"host":"x.com","paths":{"/a":{"get":{"responses":{"200":{"description":"ok"}}}}}}"#),
        ])
        let f1 = try await SpecDiscovery.discover(URL(string: "https://x.com/")!, fetch: inline.fetch)
        XCTAssertEqual(f1.result.format, "Swagger 2.0")

        let config = Fake([
            "https://x.com/ui/": Self.html(#"<script>SwaggerUIBundle({ configUrl: "/ui/swagger-config" })</script>"#),
            "https://x.com/ui/swagger-config": Self.json(#"{"urls":[{"url":"/v3/api-docs/public","name":"public"}]}"#),
            "https://x.com/v3/api-docs/public": Self.json(Self.spec),
        ])
        let f2 = try await SpecDiscovery.discover(URL(string: "https://x.com/ui/")!, fetch: config.fetch)
        XCTAssertEqual(f2.via, "Swagger UI configUrl")
    }

    func testLinkAlternate() async throws {
        let fake = Fake([
            "https://x.com/reference": Self.html(#"<link rel="stylesheet" href="/a.css"><link type="application/openapi+json" rel="alternate" href="/meta/api"><p>Docs</p>"#),
            "https://x.com/meta/api": Self.json(Self.spec),
        ])
        let f = try await SpecDiscovery.discover(URL(string: "https://x.com/reference")!, fetch: fake.fetch)
        XCTAssertEqual(f.via, "a <link rel=alternate> on the page")
    }

    func testWellKnownAtOrigin() async throws {
        let fake = Fake([
            "https://x.com/docs/guide/intro.html": Self.html("<h1>Welcome</h1><p>Use our REST API.</p>"),
            "https://x.com/openapi.json": Self.json(Self.spec),
        ])
        let f = try await SpecDiscovery.discover(URL(string: "https://x.com/docs/guide/intro.html")!, fetch: fake.fetch)
        XCTAssertEqual(f.via, "well-known path /openapi.json")
        XCTAssertTrue(fake.fetched.contains("https://x.com/docs/guide/openapi.json"), "probes the page's directory first")
    }

    func testProseOnlyIsNotFound() async throws {
        let fake = Fake(["https://x.com/": Self.html("<h1>API</h1><p>Email us for access.</p><a href=\"/pricing\">Pricing</a>")])
        do {
            _ = try await SpecDiscovery.discover(URL(string: "https://x.com/")!, fetch: fake.fetch)
            XCTFail("expected notFound")
        } catch let SpecDiscovery.Failure.notFound(page, tried) {
            XCTAssertEqual(page.host, "x.com")
            XCTAssertEqual(tried, 13) // page + 12 well-known paths at the origin
            XCTAssertEqual(fake.fetched.count, 13)
            let msg = SpecDiscovery.Failure.notFound(page: page, tried: tried).errorDescription ?? ""
            XCTAssertTrue(msg.hasPrefix("No OpenAPI/Swagger spec found on x.com (checked 13 places)."), msg)
        }
        XCTAssertLessThanOrEqual(SpecDiscovery.probeURLs(for: URL(string: "https://x.com/a/b/c/d/")!).count, SpecDiscovery.maxProbes)
    }

    func testUnreachable() async {
        do {
            _ = try await SpecDiscovery.discover(URL(string: "https://down.example/")!) { _ in throw URLError(.cannotFindHost) }
            XCTFail("expected unreachable")
        } catch SpecDiscovery.Failure.unreachable(let u, _) {
            XCTAssertEqual(u.host, "down.example")
        } catch { XCTFail("\(error)") }
    }

    func testCandidateReturningHTMLIsSkipped() async throws {
        let fake = Fake([
            "https://x.com/": Self.html(#"<a href="/swagger.json">spec</a><a href="/static/openapi.yaml">spec</a>"#),
            "https://x.com/swagger.json": Self.html("<p>Please log in</p>"),          // 200 but HTML: skipped
            "https://x.com/static/openapi.yaml": (200, "text/plain", "openapi: 3.0.0\ninfo:\n  title: Z\npaths:\n  /z:\n    get:\n      responses:\n        '200':\n          description: ok\n"),
        ])
        let f = try await SpecDiscovery.discover(URL(string: "https://x.com/")!, fetch: fake.fetch)
        XCTAssertEqual(f.via, "a link on the page")
        XCTAssertEqual(f.specURL.path, "/static/openapi.yaml")
    }

    func testBaseHrefHonoured() async throws {
        let fake = Fake([
            "https://x.com/app/page": Self.html(#"<base href="https://cdn.x.com/assets/"><rapi-doc spec-url="openapi.json"></rapi-doc>"#),
            "https://cdn.x.com/assets/openapi.json": Self.json(Self.spec),
        ])
        let f = try await SpecDiscovery.discover(URL(string: "https://x.com/app/page")!, fetch: fake.fetch)
        XCTAssertEqual(f.specURL.absoluteString, "https://cdn.x.com/assets/openapi.json")
        XCTAssertEqual(f.via, "RapiDoc spec-url")
    }

    func testRendererVariantsAndPostmanSkipped() {
        let base = URL(string: "https://x.com/docs/")!
        let page = #"""
        <a href="https://www.postman.com/x/workspace/openapi.json">Run in Postman</a>
        <elements-api apiDescriptionUrl="/e.yaml" router="hash"></elements-api>
        <openapi-explorer spec-url='o.json'></openapi-explorer>
        <script id="api-reference" type="application/json" data-url="/s.json"></script>
        <script>Redoc.init('/r.json', {}, el)</script>
        """#
        let got = SpecDiscovery.rendererCandidates(page, base: base).map { $0.0.absoluteString }
        XCTAssertEqual(got, ["https://x.com/r.json", "https://x.com/e.yaml", "https://x.com/docs/o.json", "https://x.com/s.json"])
        XCTAssertTrue(SpecDiscovery.linkCandidates(page, base: base).isEmpty, "Postman links are not importable")
    }

    func testHTMLPageAtSpecLikeURLIsNotAccepted() async {
        // Random text that happens to parse as cURL/HAR must not count as a found spec.
        let fake = Fake(["https://x.com/": (200, "text/plain", "curl https://x.com/a")])
        do { _ = try await SpecDiscovery.discover(URL(string: "https://x.com/")!, fetch: fake.fetch); XCTFail("expected notFound") }
        catch { XCTAssertTrue(error is SpecDiscovery.Failure) }
    }

    // MARK: - Live (skipped when offline)

    private func requireReachable(_ url: URL) async throws {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "HEAD"
        do { _ = try await HTTPClient.session.data(for: req) } catch { throw XCTSkip("\(url.host ?? "") not reachable: \(error.localizedDescription)") }
    }

    func testLivePetstore() async throws {
        let url = URL(string: "https://petstore3.swagger.io/")!
        try await requireReachable(url)
        let f = try await SpecDiscovery.discover(url)
        XCTAssertTrue(f.result.format.hasPrefix("OpenAPI"), f.result.format)
        XCTAssertTrue(f.result.requests.contains { $0.url.contains("/pet") }, "via \(f.via) at \(f.specURL)")
    }

    func testLiveRedoc() async throws {
        let url = URL(string: "https://redocly.github.io/redoc/")!
        try await requireReachable(url)
        let f = try await SpecDiscovery.discover(url)
        XCTAssertFalse(f.result.requests.isEmpty, "via \(f.via) at \(f.specURL)")
    }
}
