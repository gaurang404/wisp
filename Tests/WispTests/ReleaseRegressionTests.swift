import XCTest
@testable import Wisp

/// Regressions found in the pre-1.0 review.
final class ReleaseRegressionTests: XCTestCase {
    func testPlusIsEncodedInQueryValues() throws {
        var spec = RequestSpec()
        spec.url = "https://api.example.com/search?raw=a+b"          // typed by the user: left as-is
        spec.params = [KeyValue(key: "email", value: "a+tag@x.com")]
        spec.auth = Auth(kind: .apiKey, apiKeyName: "api_key", apiKeyValue: "abc+def/==", apiKeyIn: .query)
        let url = try XCTUnwrap(HTTPClient.build(spec, vars: [:]).url?.absoluteString)
        XCTAssertTrue(url.contains("raw=a+b"))
        XCTAssertTrue(url.contains("email=a%2Btag@x.com"), url)
        XCTAssertTrue(url.contains("api_key=abc%2Bdef/%3D%3D"), url)
    }

    func testOneBadHistoryEntryDoesNotLoseTheRest() throws {
        let json = #"[{"request":{"url":"https://a.io"},"duration":0.1},{"request":42},{"request":{"url":"https://b.io"}}]"#
        let items = try JSONDecoder().decode(LossyArray<HistoryEntry>.self, from: Data(json.utf8)).items
        XCTAssertEqual(items.map(\.request.url), ["https://a.io", "https://b.io"])
    }

    func testTokenDecodesWithMissingOptionalFields() throws {
        let t = try JSONDecoder().decode(OAuthToken.self, from: Data(#"{"accessToken":"x"}"#.utf8))
        XCTAssertEqual(t.accessToken, "x")
        XCTAssertEqual(t.tokenType, "Bearer")
    }

    func testEnvironmentHostComesFromBaseUrl() {
        var env = EnvSet(name: "Shop")
        XCTAssertNil(env.host)
        env.vars = [KeyValue(key: "baseUrl", value: "https://Store.MyShopify.com/admin/api/2026-10")]
        XCTAssertEqual(env.host, "store.myshopify.com")
    }

    func testImplicitOnlyOAuthIsNotWiredUp() throws {
        let spec = #"""
        {"openapi":"3.0.0","info":{"title":"T","version":"1"},"servers":[{"url":"https://api.t.io"}],
         "components":{"securitySchemes":{"o":{"type":"oauth2","flows":{"implicit":{"authorizationUrl":"https://t.io/auth","scopes":{}}}}}},
         "paths":{"/x":{"get":{"security":[{"o":[]}],"responses":{"200":{"description":"ok"}}}}}}
        """#
        let r = try Importer.parse(Data(spec.utf8))
        XCTAssertEqual(r.requests.first?.auth.kind, AuthKind.none)
    }

    func testDefaultUserAgentCanBeOverridden() throws {
        var spec = RequestSpec()
        spec.url = "https://a.io"
        XCTAssertNil(try HTTPClient.build(spec, vars: [:]).value(forHTTPHeaderField: "User-Agent"))   // added only when sending
        XCTAssertTrue(HTTPClient.userAgent.hasPrefix("Wisp/"))
        spec.headers = [KeyValue(key: "user-agent", value: "MyBot/2")]
        XCTAssertEqual(try HTTPClient.build(spec, vars: [:]).value(forHTTPHeaderField: "User-Agent"), "MyBot/2")
    }
}
