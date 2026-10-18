import XCTest
@testable import Wisp

final class SmartsTests: XCTestCase {
    private func spec(_ url: String, headers: [(String, String)] = [], auth: Auth = Auth(), params: [KeyValue] = []) -> RequestSpec {
        RequestSpec(url: url, params: params, headers: headers.map { KeyValue(key: $0.0, value: $0.1) }, auth: auth)
    }
    private func vars(_ r: ReusableResult) -> [String: String] {
        Dictionary(uniqueKeysWithValues: r.variables.map { ($0.key, $0.value) })
    }

    // MARK: apiBase

    func testAPIBase() {
        let cases = [
            "https://s.myshopify.com/admin/api/2026-10/customers.json": "https://s.myshopify.com/admin/api/2026-10",
            "https://api.stripe.com/v1/customers": "https://api.stripe.com/v1",
            "https://connect.mailerlite.com/api/subscribers": "https://connect.mailerlite.com/api",
            "https://example.com/wp-json/wc/v3/products": "https://example.com/wp-json/wc/v3",
            "https://api.github.com/repos/a/b": "https://api.github.com",
            "http://localhost:8080/api/v2.1/items?x=1": "http://localhost:8080/api/v2.1",
            "https://API.Example.com/V1/things": "https://api.example.com/V1",
            "https://example.com": "https://example.com",
            "https://example.com/rest/2024-01-15/unstable/x": "https://example.com/rest/2024-01-15/unstable",
        ]
        for (url, base) in cases { XCTAssertEqual(Reusable.apiBase(of: URL(string: url)!), base, url) }
    }

    // MARK: hasLiteralCredentials

    func testHasLiteralCredentials() {
        XCTAssertTrue(Reusable.hasLiteralCredentials(spec("https://a.com", headers: [("Authorization", "Bearer x")])))
        XCTAssertTrue(Reusable.hasLiteralCredentials(spec("https://a.com", headers: [("X-Shopify-Access-Token", "shpat")])))
        XCTAssertTrue(Reusable.hasLiteralCredentials(spec("https://a.com?api_key=abc")))
        XCTAssertTrue(Reusable.hasLiteralCredentials(spec("https://a.com", params: [KeyValue(key: "access_token", value: "t")])))
        XCTAssertTrue(Reusable.hasLiteralCredentials(spec("https://a.com", auth: Auth(kind: .bearer, token: "t"))))
        XCTAssertTrue(Reusable.hasLiteralCredentials(spec("https://a.com", auth: Auth(kind: .basic, username: "sk_test"))))
        XCTAssertFalse(Reusable.hasLiteralCredentials(spec("https://a.com", headers: [("Authorization", "Bearer {{token}}")])))
        XCTAssertFalse(Reusable.hasLiteralCredentials(spec("https://a.com", auth: Auth(kind: .bearer, token: "{{token}}"))))
        XCTAssertFalse(Reusable.hasLiteralCredentials(spec("https://a.com?api_key={{apiKey}}&page=2")))
        XCTAssertFalse(Reusable.hasLiteralCredentials(spec("https://a.com", headers: [
            ("Content-Type", "application/json"), ("Accept", "*/*"), ("User-Agent", "curl"),
            ("X-Request-Id", "abc"), ("Idempotency-Key", "k"), ("X-Wix-Site-Id", "site")])))
        XCTAssertFalse(Reusable.hasLiteralCredentials(spec("https://a.com", auth: Auth(kind: .bearer, token: ""))))
    }

    // MARK: make

    func testShopifyHeaderToken() throws {
        let s = spec("https://my-store.myshopify.com/admin/api/2026-10/customers.json?limit=5",
                     headers: [("X-Shopify-Access-Token", "shpat_abc"), ("Content-Type", "application/json")])
        let r = try XCTUnwrap(Reusable.make(s, vars: [:]))
        XCTAssertEqual(r.spec.url, "{{baseUrl}}/customers.json?limit=5")
        XCTAssertEqual(r.host, "my-store.myshopify.com")
        XCTAssertEqual(r.baseURL, "https://my-store.myshopify.com/admin/api/2026-10")
        XCTAssertEqual(r.variables.map(\.key), ["baseUrl", "shopifyAccessToken"])
        XCTAssertEqual(r.variables.map(\.secret), [false, true])
        XCTAssertEqual(r.variables[1].value, "shpat_abc")
        XCTAssertEqual(r.envAuth.kind, .apiKey)
        XCTAssertEqual(r.envAuth.apiKeyIn, .header)
        XCTAssertEqual(r.envAuth.apiKeyName, "X-Shopify-Access-Token")
        XCTAssertEqual(r.envAuth.apiKeyValue, "{{shopifyAccessToken}}")
        XCTAssertEqual(r.spec.headers.map(\.key), ["Content-Type"])
        XCTAssertEqual(r.spec.auth.kind, .none)
        XCTAssertTrue(r.envHeaders.isEmpty)
        XCTAssertEqual(r.replacements, ["shpat_abc": "{{shopifyAccessToken}}"])
    }

    func testStripeBasicUsernameOnly() throws {
        let b64 = Data("sk_test_123:".utf8).base64EncodedString()
        let r = try XCTUnwrap(Reusable.make(spec("https://api.stripe.com/v1/customers", headers: [("Authorization", "Basic \(b64)")]), vars: [:]))
        XCTAssertEqual(r.spec.url, "{{baseUrl}}/customers")
        XCTAssertEqual(r.baseURL, "https://api.stripe.com/v1")
        XCTAssertEqual(vars(r), ["baseUrl": "https://api.stripe.com/v1", "username": "sk_test_123"])
        XCTAssertEqual(r.envAuth.kind, .basic)
        XCTAssertEqual(r.envAuth.username, "{{username}}")
        XCTAssertEqual(r.envAuth.password, "")
        XCTAssertTrue(r.spec.headers.isEmpty)
    }

    func testBasicAuthTab() throws {
        let r = try XCTUnwrap(Reusable.make(spec("https://x.com/api/a", auth: Auth(kind: .basic, username: "u", password: "p")), vars: [:]))
        XCTAssertEqual(vars(r), ["baseUrl": "https://x.com/api", "username": "u", "password": "p"])
        XCTAssertEqual(r.envAuth.password, "{{password}}")
        XCTAssertEqual(r.spec.auth.kind, .none)
    }

    func testBearerHeader() throws {
        let r = try XCTUnwrap(Reusable.make(spec("https://connect.mailerlite.com/api/subscribers", headers: [("authorization", "Bearer eyJ.abc")]), vars: [:]))
        XCTAssertEqual(r.envAuth.kind, .bearer)
        XCTAssertEqual(r.envAuth.token, "{{token}}")
        XCTAssertEqual(vars(r)["token"], "eyJ.abc")
        XCTAssertEqual(r.spec.url, "{{baseUrl}}/subscribers")
        XCTAssertEqual(r.replacements, ["eyJ.abc": "{{token}}"])
    }

    func testOtherAuthorizationSchemes() throws {
        let t = try XCTUnwrap(Reusable.make(spec("https://a.com/api/x", headers: [("Authorization", "Token abc")]), vars: [:]))
        XCTAssertEqual(t.envAuth.kind, .apiKey)
        XCTAssertEqual(t.envAuth.apiKeyName, "Authorization")
        XCTAssertEqual(t.envAuth.apiKeyValue, "Token {{token}}")
        let raw = try XCTUnwrap(Reusable.make(spec("https://www.wixapis.com/v1/x", headers: [("Authorization", "IST.raw"), ("wix-site-id", "s1")]), vars: [:]))
        XCTAssertEqual(raw.envAuth.apiKeyValue, "{{apiKey}}")
        XCTAssertEqual(vars(raw)["apiKey"], "IST.raw")
        XCTAssertEqual(raw.spec.headers.map(\.key), ["wix-site-id"])
    }

    func testQueryAPIKey() throws {
        let r = try XCTUnwrap(Reusable.make(spec("https://api.example.com/v2/items?api_key=k123&page=2"), vars: [:]))
        XCTAssertEqual(r.spec.url, "{{baseUrl}}/items?page=2")
        XCTAssertEqual(r.envAuth.kind, .apiKey)
        XCTAssertEqual(r.envAuth.apiKeyIn, .query)
        XCTAssertEqual(r.envAuth.apiKeyName, "api_key")
        XCTAssertEqual(r.envAuth.apiKeyValue, "{{apiKey}}")
        XCTAssertEqual(vars(r)["apiKey"], "k123")
    }

    func testTemplatedWithoutCredentialsIsNil() {
        XCTAssertNil(Reusable.make(spec("{{baseUrl}}/customers.json"), vars: ["baseUrl": "https://a.com/api"]))
        XCTAssertNil(Reusable.make(spec("not a url"), vars: [:]))
        XCTAssertNil(Reusable.make(spec("ftp://a.com/x"), vars: [:]))
        XCTAssertNil(Reusable.make(spec("{{baseUrl}}/x", headers: [("Authorization", "Bearer t")]), vars: [:]))
    }

    func testTemplatedWithCredentials() throws {
        let r = try XCTUnwrap(Reusable.make(spec("{{baseUrl}}/customers.json?limit=1", headers: [("Authorization", "Bearer t")]),
                                            vars: ["baseUrl": "https://a.com/api"]))
        XCTAssertEqual(r.spec.url, "{{baseUrl}}/customers.json?limit=1")
        XCTAssertEqual(r.baseURL, "https://a.com/api")
        XCTAssertEqual(r.host, "a.com")
    }

    func testOtherVarsPreserved() throws {
        let s = spec("https://{{shop}}.myshopify.com/admin/api/{{apiVersion}}/orders/{{orderId}}.json?fields={{fields}}",
                     headers: [("X-Shopify-Access-Token", "shpat")])
        let r = try XCTUnwrap(Reusable.make(s, vars: ["shop": "s", "apiVersion": "2026-10"]))
        XCTAssertEqual(r.spec.url, "{{baseUrl}}/orders/{{orderId}}.json?fields={{fields}}")
        XCTAssertEqual(r.baseURL, "https://s.myshopify.com/admin/api/2026-10")
        XCTAssertNotNil(Reusable.make(spec("localhost:3000/api/x"), vars: [:]))
    }

    func testDedupeAndSecondaryCredentials() throws {
        let s = spec("https://a.com/v1/x?token=q1&key=q2",
                     headers: [("Authorization", "Bearer b1"), ("X-Auth-Token", "h1"), ("X-API-Key", "h2")])
        let r = try XCTUnwrap(Reusable.make(s, vars: [:]))
        XCTAssertEqual(r.variables.map(\.key), ["baseUrl", "token", "authToken", "apiKey", "token2", "key"])
        XCTAssertEqual(r.envAuth.token, "{{token}}")
        XCTAssertEqual(r.envHeaders.map { "\($0.key)=\($0.value)" }, ["X-Auth-Token={{authToken}}", "X-API-Key={{apiKey}}"])
        XCTAssertEqual(r.spec.url, "{{baseUrl}}/x?token={{token2}}&key={{key}}")
        XCTAssertTrue(r.spec.headers.isEmpty)
        XCTAssertEqual(r.replacements, ["b1": "{{token}}", "h1": "{{authToken}}", "h2": "{{apiKey}}", "q1": "{{token2}}", "q2": "{{key}}"])
    }

    func testUserinfoBecomesBasic() throws {
        let r = try XCTUnwrap(Reusable.make(spec("https://sk_live:@api.stripe.com/v1/charges"), vars: [:]))
        XCTAssertEqual(r.baseURL, "https://api.stripe.com/v1")
        XCTAssertEqual(r.envAuth.username, "{{username}}")
        XCTAssertEqual(vars(r)["username"], "sk_live")
    }

    // MARK: Paging

    private func next(_ s: RequestSpec, _ resolved: String?, status: Int = 200, headers: [(String, String)] = [], json: String = "{}") -> RequestSpec? {
        Paging.nextPage(for: s, resolvedURL: resolved.flatMap(URL.init(string:)), status: status, headers: headers, body: Data(json.utf8))
    }

    func testLinkHeaderKeepsTemplatedBase() throws {
        let s = spec("{{baseUrl}}/customers.json?limit=5", params: [KeyValue(key: "status", value: "any")])
        let link = #"<https://s.myshopify.com/admin/api/2026-10/customers.json?limit=5&page_info=abc>; rel="next""#
        let n = try XCTUnwrap(next(s, "https://s.myshopify.com/admin/api/2026-10/customers.json?limit=5&status=any", headers: [("link", link)]))
        XCTAssertEqual(n.url, "{{baseUrl}}/customers.json?limit=5&page_info=abc")
        XCTAssertEqual(n.params.map(\.enabled), [false])
    }

    func testLinkHeaderDifferentPath() throws {
        let link = #"<https://api.github.com/repositories/1/issues?page=2>; rel="next", <https://api.github.com/repositories/1/issues?page=9>; rel="last""#
        let n = try XCTUnwrap(next(spec("{{baseUrl}}/repos/a/b/issues"), "https://api.github.com/repos/a/b/issues", headers: [("Link", link)]))
        XCTAssertEqual(n.url, "https://api.github.com/repositories/1/issues?page=2")
    }

    func testBigCommerceQueryOnly() throws {
        let s = spec("{{baseUrl}}/catalog/products?limit=50&page=1", params: [KeyValue(key: "page", value: "1"), KeyValue(key: "x", value: "y")])
        let json = #"{"data":[],"meta":{"pagination":{"links":{"current":"?page=1&limit=50","next":"?page=2&limit=50"}}}}"#
        let n = try XCTUnwrap(next(s, "https://api.bigcommerce.com/stores/h/v3/catalog/products?limit=50&page=1", json: json))
        XCTAssertEqual(n.url, "{{baseUrl}}/catalog/products?limit=50&page=2")
        XCTAssertEqual(n.params.map(\.enabled), [false, true])
    }

    func testLaravelLinksNext() throws {
        let json = #"{"data":[],"links":{"next":"https://connect.mailerlite.com/api/subscribers?cursor=abc"},"meta":{}}"#
        let n = try XCTUnwrap(next(spec("{{baseUrl}}/subscribers?limit=10"), "https://connect.mailerlite.com/api/subscribers?limit=10", json: json))
        XCTAssertEqual(n.url, "{{baseUrl}}/subscribers?cursor=abc")
    }

    func testRelativeAndODataNext() throws {
        let rel = try XCTUnwrap(next(spec("{{baseUrl}}/a"), "https://x.com/api/a", json: #"{"next_page_url":"/api/a?page=3"}"#))
        XCTAssertEqual(rel.url, "{{baseUrl}}/a?page=3")
        let odata = try XCTUnwrap(next(spec("{{baseUrl}}/users"), "https://graph.microsoft.com/v1.0/users",
                                       json: #"{"@odata.nextLink":"https://graph.microsoft.com/v1.0/users?$skiptoken=X"}"#))
        XCTAssertEqual(odata.url, "{{baseUrl}}/users?$skiptoken=X")
        let paging = try XCTUnwrap(next(spec("{{baseUrl}}/me/feed"), "https://graph.facebook.com/v19.0/me/feed",
                                        json: #"{"paging":{"next":"https://graph.facebook.com/v19.0/me/feed?after=Q"}}"#))
        XCTAssertEqual(paging.url, "{{baseUrl}}/me/feed?after=Q")
    }

    func testLaravelMetaPages() throws {
        let n = try XCTUnwrap(next(spec("{{baseUrl}}/items?page=1"), "https://x.com/api/items?page=1",
                                   json: #"{"data":[],"links":{"next":null},"meta":{"current_page":1,"last_page":3}}"#))
        XCTAssertEqual(n.url, "{{baseUrl}}/items")
        XCTAssertEqual(n.params.map { "\($0.key)=\($0.value)" }, ["page=2"])
        let top = try XCTUnwrap(next(spec("{{baseUrl}}/items"), nil, json: #"{"current_page":2,"last_page":3}"#))
        XCTAssertEqual(top.params.last?.value, "3")
        XCTAssertNil(next(spec("{{baseUrl}}/items"), nil, json: #"{"data":[],"links":{"next":null},"meta":{"current_page":3,"last_page":3}}"#))
    }

    func testCursorMapping() throws {
        let cases = [("next_cursor", "cursor"), ("nextCursor", "cursor"), ("nextPageCursor", "cursor"),
                     ("next_page_token", "page_token"), ("nextPageToken", "pageToken")]
        for (key, param) in cases {
            let n = try XCTUnwrap(next(spec("{{baseUrl}}/x?\(param)=old"), nil, json: #"{"pagination":{"\#(key)":"C1"}}"#), key)
            XCTAssertEqual(n.url, "{{baseUrl}}/x", key)
            XCTAssertEqual(n.params.map { "\($0.key)=\($0.value)" }, ["\(param)=C1"], key)
        }
    }

    func testCursorStopsWhenNoMore() {
        XCTAssertNil(next(spec("{{baseUrl}}/x"), nil, json: #"{"pagination":{"hasNextPage":false,"nextPageCursor":"C"}}"#))
        XCTAssertNil(next(spec("{{baseUrl}}/x"), nil, json: #"{"has_more":false,"next_cursor":"C"}"#))
        XCTAssertNil(next(spec("{{baseUrl}}/x"), nil, json: #"{"next_cursor":""}"#))
    }

    func testStripeShape() throws {
        let s = spec("{{baseUrl}}/customers?limit=3&ending_before=cus_0")
        let n = try XCTUnwrap(next(s, nil, json: #"{"object":"list","has_more":true,"data":[{"id":"cus_1"},{"id":"cus_2"}]}"#))
        XCTAssertEqual(n.url, "{{baseUrl}}/customers?limit=3")
        XCTAssertEqual(n.params.map { "\($0.key)=\($0.value)" }, ["starting_after=cus_2"])
        XCTAssertNil(next(s, nil, json: #"{"has_more":false,"data":[{"id":"cus_1"}]}"#))
    }

    func testNon2xxAndNoNext() {
        let link = #"<https://a.com/x?page=2>; rel="next""#
        XCTAssertNil(next(spec("https://a.com/x"), "https://a.com/x", status: 404, headers: [("Link", link)]))
        XCTAssertNil(next(spec("https://a.com/x"), "https://a.com/x", headers: [("Link", #"<https://a.com/x?page=1>; rel="prev""#)], json: "[]"))
        XCTAssertNil(next(spec("https://a.com/x"), "https://a.com/x", json: #"{"next":null,"data":[]}"#))
    }

    func testNeverMutatesMethodBodyAuth() throws {
        var s = spec("{{baseUrl}}/search", auth: Auth(kind: .bearer, token: "{{token}}"))
        s.method = .POST; s.bodyKind = .json; s.body = #"{"q":1}"#
        let n = try XCTUnwrap(next(s, nil, json: #"{"next_cursor":"c"}"#))
        XCTAssertEqual(n.method, .POST); XCTAssertEqual(n.body, s.body); XCTAssertEqual(n.auth, s.auth)
    }

    // MARK: AuthHint

    func testBearerRealm() throws {
        let h = try XCTUnwrap(AuthHint.from(status: 401, headers: [("www-authenticate", #"Bearer realm="api.example""#)], requestAuth: .none))
        XCTAssertEqual(h.kind, .bearer)
        XCTAssertEqual(h.title, "This API wants a Bearer token")
        XCTAssertTrue(h.detail.contains("api.example"))
    }

    func testInvalidToken() throws {
        let h = try XCTUnwrap(AuthHint.from(status: 401, headers: [("WWW-Authenticate",
            #"Bearer realm="x", error="invalid_token", error_description="The access token expired, renew it""#)], requestAuth: .none))
        XCTAssertEqual(h.kind, .bearer)
        XCTAssertEqual(h.title, "The token was rejected")
        XCTAssertTrue(h.detail.contains("The access token expired, renew it"))
    }

    func testBasic() throws {
        let h = try XCTUnwrap(AuthHint.from(status: 401, headers: [("WWW-Authenticate", #"Basic realm="Admin""#)], requestAuth: .none))
        XCTAssertEqual(h.kind, .basic)
        XCTAssertEqual(h.title, "This API wants a username and password")
        XCTAssertTrue(h.detail.contains("Admin"))
    }

    func testMultipleChallengesPreferBearer() throws {
        let h = try XCTUnwrap(AuthHint.from(status: 401, headers: [("WWW-Authenticate", #"Digest realm="a", nonce="n, m", Basic realm="b""#),
                                                                    ("WWW-Authenticate", "Bearer")], requestAuth: .none))
        XCTAssertEqual(h.kind, .bearer)
        let b = try XCTUnwrap(AuthHint.from(status: 401, headers: [("WWW-Authenticate", #"Negotiate, Basic realm="b""#)], requestAuth: .none))
        XCTAssertEqual(b.kind, .basic)
    }

    func testDigestUnsupported() throws {
        let h = try XCTUnwrap(AuthHint.from(status: 401, headers: [("WWW-Authenticate", #"Digest realm="r", qop="auth""#)], requestAuth: .none))
        XCTAssertEqual(h.kind, .apiKey)
        XCTAssertEqual(h.title, "This API uses Digest auth, which Wisp doesn't support yet")
    }

    func testNoHeaderAndProxy() throws {
        let h = try XCTUnwrap(AuthHint.from(status: 401, headers: [], requestAuth: .none))
        XCTAssertEqual(h, AuthHint(kind: .bearer, title: "This API needs authentication",
                                   detail: "Most APIs take a Bearer token or an API key header — check the API docs."))
        let p = try XCTUnwrap(AuthHint.from(status: 407, headers: [("Proxy-Authenticate", "Basic")], requestAuth: .none))
        XCTAssertEqual(p.kind, .basic)
        XCTAssertNil(AuthHint.from(status: 403, headers: [("WWW-Authenticate", "Bearer")], requestAuth: .none))
        XCTAssertNil(AuthHint.from(status: 200, headers: [], requestAuth: .none))
    }

    func testRejectedWording() throws {
        let b = try XCTUnwrap(AuthHint.from(status: 401, headers: [("WWW-Authenticate", "Bearer")], requestAuth: .bearer))
        XCTAssertEqual(b.title, "The token was rejected")
        let basic = try XCTUnwrap(AuthHint.from(status: 401, headers: [("WWW-Authenticate", "Basic")], requestAuth: .basic))
        XCTAssertTrue(basic.title.contains("rejected"))
        let none = try XCTUnwrap(AuthHint.from(status: 401, headers: [], requestAuth: .apiKey))
        XCTAssertTrue(none.title.contains("rejected"))
    }
}
