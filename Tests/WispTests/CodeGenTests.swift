import XCTest
@testable import Wisp

final class CodeGenTests: XCTestCase {
    // MARK: Fixtures

    private func build(_ configure: (inout RequestSpec) -> Void) throws -> URLRequest {
        var s = RequestSpec()
        configure(&s)
        return try HTTPClient.build(s, vars: [:])
    }

    private func getWithQuery() throws -> URLRequest {
        try build {
            $0.url = "https://api.example.com/users"
            $0.params = [KeyValue(key: "page", value: "2"), KeyValue(key: "q", value: "a b")]
            $0.headers = [KeyValue(key: "Accept", value: "application/json")]
        }
    }

    private func jsonPostBearer() throws -> URLRequest {
        try build {
            $0.method = .POST
            $0.url = "https://api.example.com/users"
            $0.auth = Auth(kind: .bearer, token: "tok123")
            $0.bodyKind = .json
            $0.body = #"{"name":"Ann","active":true,"tags":["a","b"],"meta":{"x":null,"n":1.5}}"#
        }
    }

    private func formPostBasic() throws -> URLRequest {
        try build {
            $0.method = .POST
            $0.url = "https://api.example.com/login"
            $0.auth = Auth(kind: .basic, username: "bob", password: "p@ss:w")
            $0.bodyKind = .form
            $0.form = [KeyValue(key: "a", value: "1"), KeyValue(key: "msg", value: "hello world")]
        }
    }

    private func nasty() throws -> URLRequest {
        try build {
            $0.method = .PUT
            $0.url = "https://api.example.com/items"
            $0.headers = [KeyValue(key: "X-Note", value: #"it's $HOME \n "q""#)]
            $0.bodyKind = .json
            $0.body = #"{"quote":"it's","path":"C:\\dir\\$x","price":"$5","emoji":"héllo ✓ 🚀","list":[[1,2],{"deep":[false]}],"empty":{},"none":[]}"#
        }
    }

    private func all() throws -> [URLRequest] {
        [try getWithQuery(), try jsonPostBearer(), try formPostBasic(), try nasty()]
    }

    // MARK: GET with query + headers

    func testGetAllLanguages() throws {
        let r = try getWithQuery()
        let url = "https://api.example.com/users?page=2&q=a%20b"
        XCTAssertEqual(CodeGen.generate(r, language: .curl), "curl \\\n  '\(url)' \\\n  -H 'Accept: application/json'")
        XCTAssertEqual(CodeGen.generate(r, language: .httpie), "http GET '\(url)' \\\n  'Accept:application/json'")
        XCTAssertTrue(CodeGen.generate(r, language: .fetch).contains("""
        await fetch("\(url)", {
          headers: {
            "Accept": "application/json",
          },
        });
        """))
        let py = CodeGen.generate(r, language: .python)
        XCTAssertTrue(py.contains("response = requests.get(url, headers=headers)"))
        XCTAssertTrue(py.contains(#"url = "\#(url)""#))
        XCTAssertTrue(CodeGen.generate(r, language: .laravel).contains("""
        $response = Http::withHeaders([
                'Accept' => 'application/json',
            ])
            ->get('\(url)');
        """))
        let php = CodeGen.generate(r, language: .php)
        XCTAssertTrue(php.contains("CURLOPT_URL => '\(url)',"))
        XCTAssertFalse(php.contains("CURLOPT_CUSTOMREQUEST"))
        let go = CodeGen.generate(r, language: .go)
        XCTAssertTrue(go.contains(#"req, err := http.NewRequest("GET", "\#(url)", nil)"#))
        XCTAssertFalse(go.contains("\"strings\""))
        let sw = CodeGen.generate(r, language: .swift)
        XCTAssertTrue(sw.contains(#"request.setValue("application/json", forHTTPHeaderField: "Accept")"#))
        XCTAssertFalse(sw.contains("httpMethod"))
    }

    // MARK: JSON POST with bearer

    func testJSONPostBearer() throws {
        let r = try jsonPostBearer()
        let curl = CodeGen.generate(r, language: .curl)
        XCTAssertTrue(curl.contains("-X POST"))
        XCTAssertTrue(curl.contains("--data-raw '{\n  \"name\": \"Ann\","), "pretty body")

        let py = CodeGen.generate(r, language: .python)
        XCTAssertTrue(py.contains("""
        payload = {
            "name": "Ann",
            "active": True,
            "tags": [
                "a",
                "b",
            ],
            "meta": {
                "x": None,
                "n": 1.5,
            },
        }
        """))
        XCTAssertTrue(py.contains("requests.post(url, headers=headers, json=payload)"))
        XCTAssertFalse(py.contains("Content-Type"), "json= sets it")
        XCTAssertTrue(py.contains(#""Authorization": "Bearer tok123","#))

        XCTAssertTrue(CodeGen.generate(r, language: .laravel).contains("""
        $response = Http::withToken('tok123')
            ->post('https://api.example.com/users', [
                'name' => 'Ann',
                'active' => true,
                'tags' => [
                    'a',
                    'b',
                ],
                'meta' => [
                    'x' => null,
                    'n' => 1.5,
                ],
            ]);
        """))

        let js = CodeGen.generate(r, language: .fetch)
        XCTAssertTrue(js.contains(#"method: "POST","#))
        XCTAssertTrue(js.contains("body: JSON.stringify({\n    \"name\": \"Ann\","))
        XCTAssertTrue(js.contains(#""Content-Type": "application/json","#))

        let http = CodeGen.generate(r, language: .httpie)
        XCTAssertTrue(http.hasPrefix("http --raw '{\n  \"name\""))
        XCTAssertFalse(http.contains("Content-Type"))
        XCTAssertTrue(http.contains("'Authorization:Bearer tok123'"))

        let go = CodeGen.generate(r, language: .go)
        XCTAssertTrue(go.contains("\tbody := strings.NewReader(`{\n  \"name\": \"Ann\","))
        XCTAssertTrue(go.contains(#"req.Header.Set("Authorization", "Bearer tok123")"#))

        let sw = CodeGen.generate(r, language: .swift)
        XCTAssertTrue(sw.contains("request.httpBody = Data(#\"\"\"\n{\n  \"name\": \"Ann\","))
        XCTAssertTrue(sw.contains("\n\"\"\"#.utf8)"))
    }

    // MARK: Form POST with basic

    func testFormPostBasic() throws {
        let r = try formPostBasic()
        XCTAssertTrue(CodeGen.generate(r, language: .curl).contains("--data-raw 'a=1&msg=hello%20world'"))

        let lv = CodeGen.generate(r, language: .laravel)
        XCTAssertTrue(lv.contains("""
        Http::asForm()
            ->withBasicAuth('bob', 'p@ss:w')
            ->post('https://api.example.com/login', [
                'a' => '1',
                'msg' => 'hello world',
            ]);
        """))
        XCTAssertFalse(lv.contains("Authorization"))
        XCTAssertFalse(lv.contains("Content-Type"))

        let py = CodeGen.generate(r, language: .python)
        XCTAssertTrue(py.contains(#"requests.post(url, data=payload, auth=("bob", "p@ss:w"))"#))
        XCTAssertFalse(py.contains("headers"))

        let http = CodeGen.generate(r, language: .httpie)
        XCTAssertTrue(http.hasPrefix("http -a 'bob:p@ss:w' --form POST"))
        XCTAssertTrue(http.contains("'msg=hello world'"))

        XCTAssertTrue(CodeGen.generate(r, language: .go).contains(#"req.SetBasicAuth("bob", "p@ss:w")"#))
        let js = CodeGen.generate(r, language: .fetch)
        XCTAssertTrue(js.contains("body: new URLSearchParams({"))
        XCTAssertFalse(js.contains("Content-Type"))
        XCTAssertTrue(CodeGen.generate(r, language: .php).contains("CURLOPT_POSTFIELDS => 'a=1&msg=hello%20world',"))
    }

    // MARK: Escaping

    func testEscaping() throws {
        let r = try nasty()

        XCTAssertTrue(CodeGen.generate(r, language: .curl).contains(#"-H 'X-Note: it'\''s $HOME \n "q"'"#))

        let py = CodeGen.generate(r, language: .python)
        XCTAssertTrue(py.contains(#""X-Note": "it's $HOME \\n \"q\"","#))
        XCTAssertTrue(py.contains(#""path": "C:\\dir\\$x","#))
        XCTAssertTrue(py.contains(#""emoji": "héllo ✓ 🚀","#))
        XCTAssertTrue(py.contains("\"list\": [\n        [\n            1,\n            2,\n        ],\n        {\n            \"deep\": [\n                False,"))
        XCTAssertTrue(py.contains(#""empty": {},"#))
        XCTAssertTrue(py.contains(#""none": [],"#))

        let lv = CodeGen.generate(r, language: .laravel)
        XCTAssertTrue(lv.contains(#"'X-Note' => 'it\'s $HOME \\n "q"',"#))
        XCTAssertTrue(lv.contains(#"'quote' => 'it\'s',"#))
        XCTAssertTrue(lv.contains(#"'path' => 'C:\\dir\\$x',"#))
        XCTAssertTrue(lv.contains(#"'price' => '$5',"#))
        XCTAssertTrue(lv.contains("'empty' => (object) [],"))
        XCTAssertTrue(lv.contains("->put("))

        let js = CodeGen.generate(r, language: .fetch)
        XCTAssertTrue(js.contains(#""X-Note": "it's $HOME \\n \"q\"","#))

        XCTAssertTrue(CodeGen.generate(r, language: .go).contains(#"req.Header.Set("X-Note", "it's $HOME \\n \"q\"")"#))
        XCTAssertTrue(CodeGen.generate(r, language: .swift).contains(#"request.setValue("it's $HOME \\n \"q\"", forHTTPHeaderField: "X-Note")"#))
        XCTAssertTrue(CodeGen.generate(r, language: .php).contains(#"'X-Note: it\'s $HOME \\n "q"',"#))
    }

    func testQuoteHelpers() {
        XCTAssertEqual(Quote.php(#"a'b\c$d"#), #"'a\'b\\c$d'"#)
        XCTAssertEqual(Quote.dq("a\u{1}b"), #""a\u0001b""#)
        XCTAssertEqual(Quote.dq("a\u{1}b", swift: true), #""a\u{1}b""#)
        XCTAssertEqual(Quote.goRaw("x`y"), #""x`y""#)
        XCTAssertEqual(Quote.goRaw("x\ny"), "`x\ny`")
        XCTAssertEqual(Quote.swift("a\n\"#b"), "##\"\"\"\na\n\"#b\n\"\"\"##")
    }

    func testJSONOrderPreserved() {
        guard case .object(let kv)? = JSONValue.parse(#"{"z":1,"a":{"y":"\u00e9\"","b":[true,null]}}"#) else { return XCTFail() }
        XCTAssertEqual(kv.map(\.0), ["z", "a"])
        guard case .object(let inner) = kv[1].1, case .string(let s) = inner[0].1 else { return XCTFail() }
        XCTAssertEqual(s, "é\"")
    }

    func testRawTextAndOptions() throws {
        let r = try build {
            $0.method = .OPTIONS
            $0.url = "https://x.io/a"
            $0.bodyKind = .text
            $0.body = "line1\nline`2"
        }
        XCTAssertTrue(CodeGen.generate(r, language: .laravel).contains("->send('OPTIONS', 'https://x.io/a')"))
        XCTAssertTrue(CodeGen.generate(r, language: .go).contains(#"strings.NewReader("line1\nline`2")"#))
        XCTAssertTrue(CodeGen.generate(r, language: .python).contains("requests.options(url, headers=headers, data=payload.encode(\"utf-8\"))"))
    }

    // MARK: Optional syntax checks with local toolchains

    private func which(_ tool: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", NSHomeDirectory() + "/.nix-profile/bin"]
        return paths.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func check(_ tool: String, _ args: [String], ext: String, language: CodeLanguage, prefix: String = "") throws {
        guard let exe = which(tool) else { throw XCTSkip("\(tool) not installed") }
        for r in try all() {
            let code = prefix + CodeGen.generate(r, language: language)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-codegen-\(UUID().uuidString).\(ext)")
            try code.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args + [file.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(p.terminationStatus, 0, "\(language.rawValue) failed \(tool):\n\(out)\n---\n\(code)")
        }
    }

    func testPythonSyntax() throws {
        try check("python3", ["-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())"], ext: "py", language: .python)
    }

    func testPHPSyntax() throws {
        try check("php", ["-l"], ext: "php", language: .php)
        try check("php", ["-l"], ext: "php", language: .laravel, prefix: "<?php\n")
    }

    func testNodeSyntax() throws {
        try check("node", ["--check"], ext: "mjs", language: .fetch)
    }

    func testGoSyntax() throws {
        try check("gofmt", ["-e", "-l"], ext: "go", language: .go)
    }

    func testShellSyntax() throws {
        try check("sh", ["-n"], ext: "sh", language: .curl)
        try check("sh", ["-n"], ext: "sh", language: .httpie)
    }

    func testSwiftSyntax() throws {
        try check("swiftc", ["-parse"], ext: "swift", language: .swift)
    }

    // MARK: DocsExport

    func testDocsExport() {
        var a = RequestSpec(name: "List users", method: .GET, url: "{{base}}/users", folder: "Users")
        a.params = [KeyValue(key: "page", value: "1"), KeyValue(enabled: false, key: "hidden", value: "x"),
                    KeyValue(key: "api_key", value: "qsecret")]
        a.headers = [KeyValue(key: "X-API-Key", value: "hsecret"), KeyValue(key: "Accept", value: "application/json")]
        a.docs = "Returns **all** users."
        var b = RequestSpec(name: "Create order", method: .POST, url: "{{base}}/orders", folder: "Orders")
        b.auth = Auth(kind: .bearer, token: "{{token}}")
        b.bodyKind = .json
        b.body = #"{"sku":"A1"}"#
        var c = RequestSpec(name: "Get user", method: .GET, url: "{{base}}/users/1", folder: "Users")
        c.auth = Auth(kind: .basic, username: "bob", password: "bsecret")
        let d = RequestSpec(name: "Broken", url: "{{missing}}/x", folder: "Orders")

        let md = DocsExport.markdown(title: "Shop API", requests: [a, b, c, d],
                                     vars: ["base": "https://api.shop.io", "token": "tsecret"])

        XCTAssertTrue(md.hasPrefix("# Shop API\n\n_Generated by Wisp on "))
        XCTAssertTrue(md.contains("""
        ## Contents

        - [Users](#users)
          - [GET List users](#get-list-users)
          - [GET Get user](#get-get-user)
        - [Orders](#orders)
          - [POST Create order](#post-create-order)
          - [GET Broken](#get-broken)
        """))
        let order = ["## Users", "### GET List users", "### GET Get user", "## Orders", "### POST Create order", "### GET Broken"]
            .map { md.range(of: "\n\($0)\n")!.lowerBound }
        XCTAssertEqual(order, order.sorted())

        for secret in ["hsecret", "qsecret", "tsecret", "bsecret", "Ym9i"] {
            XCTAssertFalse(md.contains(secret), "leaked \(secret)")
        }
        XCTAssertTrue(md.contains("Returns **all** users."))
        XCTAssertTrue(md.contains("| `page` | 1 |"))
        XCTAssertFalse(md.contains("hidden"))
        XCTAssertTrue(md.contains("| `X-API-Key` | ••• |"))
        XCTAssertTrue(md.contains("**Auth:** Bearer"))
        XCTAssertTrue(md.contains("**Auth:** Basic"))
        XCTAssertTrue(md.contains("```json\n{\n  \"sku\": \"A1\"\n}\n```"))
        XCTAssertTrue(md.contains("curl \\\n  -X POST \\\n  'https://api.shop.io/orders'"))
        XCTAssertTrue(md.contains("-H 'Authorization: Bearer •••'"))
        XCTAssertTrue(md.contains("-H 'Authorization: Basic •••'"))
        XCTAssertTrue(md.contains("api_key=%E2%80%A2%E2%80%A2%E2%80%A2"))
        XCTAssertTrue(md.contains("_Example unavailable"))
    }

    func testDocsDuplicateAnchors() {
        let r = RequestSpec(name: "Ping", url: "https://x.io")
        let md = DocsExport.markdown(title: "API", requests: [r, r], vars: [:])
        XCTAssertTrue(md.contains("- [General](#general)"))
        XCTAssertTrue(md.contains("  - [GET Ping](#get-ping)\n  - [GET Ping](#get-ping-1)"))
    }
}
