import AppKit
import XCTest
@testable import Wisp

/// Opt-in micro-benchmarks: `WISP_BENCH=1 swift test -c release --filter BenchTests`
final class BenchTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WISP_BENCH"] == "1", "set WISP_BENCH=1 to run benchmarks")
    }

    /// Median wall time in ms over `runs`.
    private func measureMs(_ label: String, runs: Int = 5, _ block: () -> Void) {
        var times: [Double] = []
        for _ in 0..<runs {
            let t0 = DispatchTime.now().uptimeNanoseconds
            block()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: "BENCH %-44@ %9.2f ms", label as NSString, median))
    }

    private func json(items: Int) -> String {
        let one = #"{"id":%d,"name":"Customer %d","email":"user%d@example.com","active":true,"balance":1234.56,"tags":["vip","eu"],"address":{"city":"Berlin","zip":"10115"}}"#
        return "[" + (0..<items).map { String(format: one, $0, $0, $0) }.joined(separator: ",") + "]"
    }

    func testJSONFormatting() {
        for (label, items) in [("1 MB", 6_500), ("10 MB", 65_000)] {
            let raw = json(items: items)
            let size = String(format: "%.1f MB", Double(raw.utf8.count) / 1_048_576)
            measureMs("pretty-print \(label) (\(size))") { _ = JSONFormat.pretty(raw) }
            let data = Data(raw.utf8)
            measureMs("filter [-1].address.city \(label)") { _ = JSONFormat.query(data, path: "[-1].address.city") }
        }
        // Largest document that still gets highlighted (JSONFormat.highlightLimit = 1.5M UTF-16 units).
        let pretty = JSONFormat.pretty(json(items: 14_000))!
        XCTAssertLessThan((pretty as NSString).length, JSONFormat.highlightLimit)
        measureMs(String(format: "syntax-highlight %.1f MB (near limit)", Double(pretty.utf8.count) / 1_048_576)) {
            let storage = NSTextStorage(string: pretty)
            JSONFormat.highlight(storage)
        }
    }

    func testParsers() {
        let curl = """
        curl 'https://api.example.com/v1/users?page=2' -H 'accept: application/json' -H 'authorization: Bearer abc' --data-raw '{"name":"x","n":1}' --compressed
        """
        measureMs("cURL parse ×1000") { for _ in 0..<1000 { _ = Curl.parse(curl) } }

        var paths: [String] = []
        for i in 0..<200 {
            paths.append(#""/items\#(i)/{id}": {"get": {"summary": "Get item \#(i)", "tags": ["t\#(i % 10)"], "parameters": [{"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}}, {"name": "q", "in": "query", "schema": {"type": "string"}}], "responses": {"200": {"description": "ok"}}}}"#)
        }
        let openapi = #"{"openapi": "3.0.0", "info": {"title": "Bench", "version": "1"}, "servers": [{"url": "https://api.example.com"}], "paths": {"# + paths.joined(separator: ",") + "}}"
        measureMs("OpenAPI import, 200 ops (JSON)") { _ = try? Importer.parse(Data(openapi.utf8)) }

        var yaml = "openapi: 3.0.0\ninfo:\n  title: Bench\n  version: '1'\nservers:\n  - url: https://api.example.com\npaths:\n"
        for i in 0..<200 {
            yaml += "  /items\(i)/{id}:\n    get:\n      summary: Get item \(i)\n      tags: [t\(i % 10)]\n      parameters:\n        - name: id\n          in: path\n          required: true\n          schema:\n            type: integer\n      responses:\n        '200':\n          description: ok\n"
        }
        measureMs("OpenAPI import, 200 ops (YAML)") { _ = try? Importer.parse(Data(yaml.utf8)) }
        XCTAssertEqual((try? Importer.parse(Data(yaml.utf8)))?.requests.count, 200)
    }

    /// Sequential GETs through Wisp's HTTP stack; compare with curl in the bench script.
    func testRequestLatency() async throws {
        let url = ProcessInfo.processInfo.environment["WISP_BENCH_URL"] ?? "http://127.0.0.1:8765/small.json"
        var spec = RequestSpec()
        spec.url = url
        let req = try HTTPClient.build(spec, vars: [:])
        _ = try await HTTPClient.send(req)   // warm-up (DNS/TLS)
        var times: [Double] = []
        for _ in 0..<20 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try await HTTPClient.send(req)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        print(String(format: "BENCH %-44@ %9.2f ms", "Wisp request median (20×) \(url)" as NSString, times.sorted()[10]))
    }
}
