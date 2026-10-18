import XCTest
@testable import Wisp

final class CoreTests: XCTestCase {
    func testCurlChromeStyle() throws {
        let cmd = """
        curl 'https://api.example.com/v1/users?page=2' \\
          -H 'accept: application/json' \\
          -H 'authorization: Bearer abc' \\
          --data-raw $'{"name":"it\\'s","n":1}' \\
          --compressed
        """
        let s = try XCTUnwrap(Curl.parse(cmd))
        XCTAssertEqual(s.method, .POST)
        XCTAssertEqual(s.url, "https://api.example.com/v1/users?page=2")
        XCTAssertEqual(s.headers.count, 2)
        XCTAssertEqual(s.bodyKind, .json)
        XCTAssertTrue(s.body.contains("\"name\": \"it's\""))
    }

    func testCurlFormAndUser() throws {
        let s = try XCTUnwrap(Curl.parse("curl -X PUT -u bob:s3cret https://x.io/a -d 'a=1&b=hello+world%21'"))
        XCTAssertEqual(s.method, .PUT)
        XCTAssertEqual(s.auth.kind, .basic)
        XCTAssertEqual(s.auth.password, "s3cret")
        XCTAssertEqual(s.bodyKind, .form)
        XCTAssertEqual(s.form.map(\.value), ["1", "hello world!"])
    }

    func testCurlRejectsNonCurl() {
        XCTAssertNil(Curl.parse("wget https://x.io"))
    }

    func testCurlRoundTrip() throws {
        var spec = RequestSpec()
        spec.method = .POST
        spec.url = "https://x.io/{{v}}/items"
        spec.headers = [KeyValue(key: "X-Q", value: "it's")]
        spec.bodyKind = .json
        spec.body = #"{"a":1}"#
        let req = try HTTPClient.build(spec, vars: ["v": "v2"])
        let back = try XCTUnwrap(Curl.parse(Curl.export(req)))
        XCTAssertEqual(back.url, "https://x.io/v2/items")
        XCTAssertEqual(back.method, .POST)
        XCTAssertEqual(back.headers.first { $0.key == "X-Q" }?.value, "it's")
    }

    func testPrettyPreservesOrder() throws {
        let p = try XCTUnwrap(JSONFormat.pretty(#"{"z":1,"a":[],"m":{"s":"x,{y}:\"q\""}}"#))
        XCTAssertEqual(p, """
        {
          "z": 1,
          "a": [],
          "m": {
            "s": "x,{y}:\\"q\\""
          }
        }
        """)
        XCTAssertNil(JSONFormat.pretty("not json"))
    }

    func testQuery() {
        let d = Data(#"{"data":{"items":[{"id":1,"name":"a"},{"id":2,"name":"b"}]}}"#.utf8)
        XCTAssertEqual(JSONFormat.query(d, path: "data.items[1].name"), "\"b\"")
        XCTAssertEqual(JSONFormat.query(d, path: "$.data.items.#"), "2")
        XCTAssertEqual(JSONFormat.query(d, path: "data.items.id")?.filter { !$0.isWhitespace }, "[1,2]")
        XCTAssertEqual(JSONFormat.query(d, path: "data.items[-1].id"), "2")
        XCTAssertNil(JSONFormat.query(d, path: "data.nope"))
    }

    func testBuild() throws {
        var spec = RequestSpec()
        spec.url = "localhost:8000/api?x=1"
        spec.params = [KeyValue(key: "q", value: "{{ term }}"), KeyValue(enabled: false, key: "off", value: "1")]
        spec.auth = Auth(kind: .bearer, token: "{{tok}}")
        spec.bodyKind = .form
        spec.form = [KeyValue(key: "a", value: "1+1=2")]
        let req = try HTTPClient.build(spec, vars: ["term": "hi there", "tok": "T"])
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:8000/api?x=1&q=hi%20there")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer T")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(String(decoding: req.httpBody!, as: UTF8.self), "a=1%2B1%3D2")
    }

    func testHighlightTokens() {
        let text = "{\n  \"id\": 12, \"ok\": true, \"n\": null, \"s\": \"a \\\"q\\\" 5\", \"neg\": -1.5e3\n}"
        let storage = NSTextStorage(string: text)
        JSONFormat.highlight(storage)
        func color(_ needle: String) -> NSColor? {
            let r = (text as NSString).range(of: needle)
            return storage.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual(color("\"id\""), .systemBlue)
        XCTAssertEqual(color("12"), .systemPurple)
        XCTAssertEqual(color("true"), .systemPink)
        XCTAssertEqual(color("null"), .systemPink)
        XCTAssertEqual(color("\"a "), .systemOrange)
        XCTAssertEqual(color(" 5\""), .systemOrange)          // digits inside strings stay string-coloured
        XCTAssertEqual(color("-1.5e3"), .systemPurple)
    }

    func testNoHTTPCaching() {
        // API clients must always show the live server response.
        XCTAssertNil(HTTPClient.session.configuration.urlCache)
        XCTAssertEqual(HTTPClient.session.configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testResolverLeavesUnknown() {
        XCTAssertEqual(Resolver(vars: ["a": "1"])("{{a}}-{{b}}"), "1-{{b}}")
    }
}
