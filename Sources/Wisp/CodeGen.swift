import Foundation

enum CodeLanguage: String, CaseIterable, Identifiable {
    case curl = "cURL", httpie = "HTTPie", fetch = "JavaScript fetch", python = "Python requests",
         laravel = "PHP Laravel Http", php = "PHP cURL", go = "Go net/http", swift = "Swift URLSession"
    var id: String { rawValue }
}

enum CodeGen {
    /// Generates code from a fully built URLRequest (env vars already resolved, auth already applied as headers/query).
    static func generate(_ req: URLRequest, language: CodeLanguage) -> String {
        let p = Parsed(req)
        switch language {
        case .curl: return curl(req, p)
        case .httpie: return httpie(p)
        case .fetch: return fetch(p)
        case .python: return python(p)
        case .laravel: return laravel(p)
        case .php: return phpCurl(p)
        case .go: return go(p)
        case .swift: return swift(p)
        }
    }

    // MARK: - Targets

    private static func curl(_ req: URLRequest, _ p: Parsed) -> String {
        var r = req
        if case .json(_, let pretty) = p.body { r.httpBody = Data(pretty.utf8) }
        return Curl.export(r)
    }

    private static func httpie(_ p: Parsed) -> String {
        var head = ["http"]
        var items: [String] = []
        var headers = p.headers
        if let b = p.basic {
            head.append("-a " + Quote.sh("\(b.user):\(b.pass)"))
            headers = p.headers(without: ["authorization"])
        }
        switch p.body {
        case .none: break
        case .json(_, let pretty):
            head.append("--raw " + Quote.sh(pretty))
            if p.autoContentType { headers = drop("content-type", from: headers) }
        case .form(let pairs):
            head.append("--form")
            if p.autoContentType { headers = drop("content-type", from: headers) }
            items += pairs.map { Quote.sh(httpieKey($0.0) + "=" + $0.1) }
        case .raw(let s):
            head.append("--raw " + Quote.sh(s))
        }
        head += [p.method, Quote.sh(p.url)]
        let hs = headers.map { Quote.sh($0.1.isEmpty ? "\($0.0);" : "\($0.0):\($0.1)") }
        return ([head.joined(separator: " ")] + hs + items).joined(separator: " \\\n  ")
    }

    private static func fetch(_ p: Parsed) -> String {
        var headers = p.headers
        var opts: [String] = []
        if p.method != "GET" { opts.append("method: \(Quote.dq(p.method)),") }
        var body: String?
        switch p.body {
        case .none: break
        case .json(_, let pretty): body = "JSON.stringify(\(indent(pretty, by: 2)))"
        case .form(let pairs) where Set(pairs.map(\.0)).count == pairs.count:
            if p.autoContentType { headers = drop("content-type", from: headers) }
            body = "new URLSearchParams(\(render(.object(pairs.map { ($0.0, .string($0.1)) }), .js, level: 1)))"
        case .form: body = Quote.dq(p.rawBody)
        case .raw(let s): body = Quote.dq(s)
        }
        if !headers.isEmpty { opts.append("headers: \(render(stringObject(headers), .js, level: 1)),") }
        if let body { opts.append("body: \(body),") }
        let call = opts.isEmpty ? "fetch(\(Quote.dq(p.url)))"
            : "fetch(\(Quote.dq(p.url)), {\n" + opts.map { "  " + $0 }.joined(separator: "\n") + "\n})"
        return """
        const response = await \(call);

        console.log(response.status);
        console.log(await response.text());
        """
    }

    private static func python(_ p: Parsed) -> String {
        var headers = p.headers
        var lines = ["import requests", "", "url = \(Quote.dq(p.url))"]
        var args = ["url"]
        var payload: String?
        switch p.body {
        case .none: break
        case .json(let v, _):
            payload = "payload = " + render(v, .python, level: 0)
            args.append("json=payload")
        case .form(let pairs):
            payload = "payload = " + render(.object(pairs.map { ($0.0, .string($0.1)) }), .python, level: 0)
            args.append("data=payload")
        case .raw(let s):
            payload = "payload = " + Quote.dq(s)
            args.append("data=payload.encode(\"utf-8\")")
        }
        if p.autoContentType { headers = drop("content-type", from: headers) }
        if let b = p.basic {
            headers = drop("authorization", from: headers)
            args.append("auth=(\(Quote.dq(b.user)), \(Quote.dq(b.pass)))")
        }
        if !headers.isEmpty {
            lines.append("headers = " + render(stringObject(headers), .python, level: 0))
            args.insert("headers=headers", at: 1)
        }
        if let payload { lines.append(payload) }
        lines += ["", "response = requests.\(p.method.lowercased())(\(args.joined(separator: ", ")))",
                  "print(response.status_code)", "print(response.text)"]
        return lines.joined(separator: "\n")
    }

    private static func laravel(_ p: Parsed) -> String {
        var chain: [String] = []
        var headers = p.headers
        if let t = p.bearer {
            chain.append("withToken(\(Quote.php(t)))")
            headers = drop("authorization", from: headers)
        } else if let b = p.basic {
            chain.append("withBasicAuth(\(Quote.php(b.user)), \(Quote.php(b.pass)))")
            headers = drop("authorization", from: headers)
        }
        if case .form = p.body { chain.insert("asForm()", at: 0) }
        if p.autoContentType { headers = drop("content-type", from: headers) }
        let level = (chain.isEmpty && headers.isEmpty) ? 0 : 1
        if !headers.isEmpty { chain.append("withHeaders(\(render(stringObject(headers), .php, level: level)))") }

        let verbs = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
        let verb = verbs.contains(p.method) ? p.method.lowercased() : nil
        let url = Quote.php(p.url)
        var data: JSONValue?
        switch p.body {
        case .none: break
        case .json(let v, _) where p.method != "GET" && p.method != "HEAD" && verb != nil: data = v
        case .form(let pairs) where verb != nil && p.method != "GET" && p.method != "HEAD":
            data = .object(pairs.map { ($0.0, .string($0.1)) })
        case .json(_, let s), .raw(let s):
            chain.append("withBody(\(Quote.php(s)), \(Quote.php(p.contentType ?? "text/plain")))")
        case .form:
            chain.append("withBody(\(Quote.php(p.rawBody)), 'application/x-www-form-urlencoded')")
        }
        var call: String
        if let verb {
            call = "\(verb)(\(url)" + (data.map { ", " + render($0, .php, level: level) } ?? "") + ")"
        } else {
            call = "send(\(Quote.php(p.method)), \(url))"
        }
        chain.append(call)
        let expr = "Http::" + chain.joined(separator: "\n    ->")
        return """
        use Illuminate\\Support\\Facades\\Http;

        $response = \(expr);

        echo $response->status() . PHP_EOL;
        echo $response->body();
        """
    }

    private static func phpCurl(_ p: Parsed) -> String {
        var opts = ["CURLOPT_URL => \(Quote.php(p.url)),", "CURLOPT_RETURNTRANSFER => true,"]
        if p.method == "HEAD" { opts.append("CURLOPT_NOBODY => true,") }
        else if p.method != "GET" { opts.append("CURLOPT_CUSTOMREQUEST => \(Quote.php(p.method)),") }
        if !p.headers.isEmpty {
            opts.append("CURLOPT_HTTPHEADER => [\n" + p.headers.map { "        \(Quote.php("\($0.0): \($0.1)"))," }
                .joined(separator: "\n") + "\n    ],")
        }
        if let body = p.displayBody { opts.append("CURLOPT_POSTFIELDS => \(Quote.php(body)),") }
        return """
        <?php

        $ch = curl_init();
        curl_setopt_array($ch, [
        \(opts.map { "    " + $0 }.joined(separator: "\n"))
        ]);

        $response = curl_exec($ch);
        if ($response === false) {
            echo 'Error: ' . curl_error($ch) . PHP_EOL;
        } else {
            echo curl_getinfo($ch, CURLINFO_RESPONSE_CODE) . PHP_EOL;
            echo $response;
        }
        curl_close($ch);
        """
    }

    private static func go(_ p: Parsed) -> String {
        var headers = p.headers
        var imports = ["fmt", "io", "log", "net/http"]
        var lines: [String] = []
        var bodyArg = "nil"
        if let body = p.displayBody {
            imports.append("strings")
            lines.append("body := strings.NewReader(\(Quote.goRaw(body)))")
            bodyArg = "body"
        }
        lines += ["req, err := http.NewRequest(\(Quote.dq(p.method)), \(Quote.dq(p.url)), \(bodyArg))",
                  "if err != nil {", "\tlog.Fatal(err)", "}"]
        if let b = p.basic {
            headers = drop("authorization", from: headers)
            lines.append("req.SetBasicAuth(\(Quote.dq(b.user)), \(Quote.dq(b.pass)))")
        }
        lines += headers.map { "req.Header.Set(\(Quote.dq($0.0)), \(Quote.dq($0.1)))" }
        lines += ["", "resp, err := http.DefaultClient.Do(req)", "if err != nil {", "\tlog.Fatal(err)", "}",
                  "defer resp.Body.Close()", "",
                  "data, err := io.ReadAll(resp.Body)", "if err != nil {", "\tlog.Fatal(err)", "}",
                  "fmt.Println(resp.Status)", "fmt.Println(string(data))"]
        // Only a statement's first line is indented; raw-string bodies stay verbatim.
        let body = lines.map { $0.isEmpty ? $0 : "\t" + $0 }
        return """
        package main

        import (
        \(imports.sorted().map { "\t\"\($0)\"" }.joined(separator: "\n"))
        )

        func main() {
        \(body.joined(separator: "\n"))
        }
        """
    }

    private static func swift(_ p: Parsed) -> String {
        var lines = ["import Foundation", "", "var request = URLRequest(url: URL(string: \(Quote.dq(p.url, swift: true)))!)"]
        if p.method != "GET" { lines.append("request.httpMethod = \(Quote.dq(p.method))") }
        lines += p.headers.map {
            "request.setValue(\(Quote.dq($0.1, swift: true)), forHTTPHeaderField: \(Quote.dq($0.0, swift: true)))"
        }
        if let body = p.displayBody { lines.append("request.httpBody = Data(\(Quote.swift(body)).utf8)") }
        lines += ["", "let (data, response) = try await URLSession.shared.data(for: request)",
                  "print((response as? HTTPURLResponse)?.statusCode ?? 0)",
                  "print(String(decoding: data, as: UTF8.self))"]
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func drop(_ name: String, from h: [(String, String)]) -> [(String, String)] {
        h.filter { $0.0.lowercased() != name }
    }

    private static func stringObject(_ pairs: [(String, String)]) -> JSONValue {
        .object(pairs.map { ($0.0, .string($0.1)) })
    }

    /// Escapes HTTPie item separators inside a field name.
    private static func httpieKey(_ k: String) -> String {
        k.reduce(into: "") { out, c in
            if "\\:=@".contains(c) { out.append("\\") }
            out.append(c)
        }
    }

    private static func indent(_ s: String, by n: Int) -> String {
        s.replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: n))
    }

    // MARK: - Literal rendering (JSON → Python dict / PHP array / JS object)

    private struct Style {
        var open = "{", close = "}", empty = "{}", sep = ": ", t = "true", f = "false", null = "null"
        var str: (String) -> String = { Quote.dq($0) }
        var indent = "  "

        static let js = Style()
        static let python = Style(t: "True", f: "False", null: "None", indent: "    ")
        static let php = Style(open: "[", close: "]", empty: "(object) []", sep: " => ",
                               str: { Quote.php($0) }, indent: "    ")
    }

    private static func render(_ v: JSONValue, _ st: Style, level: Int) -> String {
        let pad = String(repeating: st.indent, count: level + 1)
        let end = String(repeating: st.indent, count: level)
        switch v {
        case .object(let kv):
            if kv.isEmpty { return st.empty }
            let items = kv.map { pad + st.str($0.0) + st.sep + render($0.1, st, level: level + 1) + "," }
            return st.open + "\n" + items.joined(separator: "\n") + "\n" + end + st.close
        case .array(let a):
            if a.isEmpty { return "[]" }
            let items = a.map { pad + render($0, st, level: level + 1) + "," }
            return "[\n" + items.joined(separator: "\n") + "\n" + end + "]"
        case .string(let s): return st.str(s)
        case .number(let n): return n
        case .bool(let b): return b ? st.t : st.f
        case .null: return st.null
        }
    }
}

// MARK: - Request analysis

private struct Parsed {
    enum Body {
        case none, json(JSONValue, pretty: String), form([(String, String)]), raw(String)
    }

    let method: String
    let url: String
    /// Sorted by name for stable output.
    let headers: [(String, String)]
    let body: Body
    let rawBody: String
    let contentType: String?

    init(_ req: URLRequest) {
        method = (req.httpMethod ?? "GET").uppercased()
        url = req.url?.absoluteString ?? ""
        headers = (req.allHTTPHeaderFields ?? [:]).sorted { $0.key.lowercased() < $1.key.lowercased() }.map { ($0.key, $0.value) }
        contentType = headers.first { $0.0.lowercased() == "content-type" }?.1
        rawBody = req.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let ct = contentType?.lowercased() ?? ""
        if rawBody.isEmpty {
            body = .none
        } else if ct.contains("json"), let v = JSONValue.parse(rawBody), v.isContainer {
            body = .json(v, pretty: JSONFormat.pretty(rawBody) ?? rawBody)
        } else if ct.contains("x-www-form-urlencoded") {
            body = .form(rawBody.split(separator: "&").map { pair in
                let kv = pair.split(separator: "=", maxSplits: 1).map {
                    $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
                }
                return (kv[0], kv.count > 1 ? kv[1] : "")
            })
        } else {
            body = .raw(rawBody)
        }
    }

    /// Body as it should appear verbatim in code (JSON pretty-printed).
    var displayBody: String? {
        switch body {
        case .none: return nil
        case .json(_, let pretty): return pretty
        case .form, .raw: return rawBody
        }
    }

    /// True when Content-Type is exactly what JSON/form idioms set on their own.
    var autoContentType: Bool {
        let ct = contentType?.lowercased() ?? ""
        switch body {
        case .json: return ct.hasPrefix("application/json")
        case .form: return ct.hasPrefix("application/x-www-form-urlencoded")
        default: return false
        }
    }

    private var authorization: String? { headers.first { $0.0.lowercased() == "authorization" }?.1 }

    var bearer: String? {
        guard let a = authorization, a.lowercased().hasPrefix("bearer ") else { return nil }
        return String(a.dropFirst(7))
    }

    var basic: (user: String, pass: String)? {
        guard let a = authorization, a.lowercased().hasPrefix("basic "),
              let d = Data(base64Encoded: String(a.dropFirst(6))), let s = String(data: d, encoding: .utf8)
        else { return nil }
        let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }

    func headers(without names: Set<String>) -> [(String, String)] {
        headers.filter { !names.contains($0.0.lowercased()) }
    }
}

// MARK: - Order-preserving JSON tree

enum JSONValue {
    case object([(String, JSONValue)]), array([JSONValue]), string(String), number(String), bool(Bool), null

    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    /// Parses JSON keeping key order (JSONSerialization validates; this walk only builds the tree).
    static func parse(_ text: String) -> JSONValue? {
        let data = Data(text.utf8)
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
        var i = 0
        return value(Array(data), &i)
    }

    private static func value(_ b: [UInt8], _ i: inout Int) -> JSONValue? {
        func skip() { while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 } }
        skip()
        guard i < b.count else { return nil }
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1; skip()
            var items: [(String, JSONValue)] = []
            while i < b.count, b[i] != UInt8(ascii: "}") {
                guard case .string(let k)? = value(b, &i) else { return nil }
                skip(); i += 1 // ':'
                guard let v = value(b, &i) else { return nil }
                items.append((k, v))
                skip(); if b[i] == UInt8(ascii: ",") { i += 1; skip() }
            }
            i += 1
            return .object(items)
        case UInt8(ascii: "["):
            i += 1; skip()
            var items: [JSONValue] = []
            while i < b.count, b[i] != UInt8(ascii: "]") {
                guard let v = value(b, &i) else { return nil }
                items.append(v)
                skip(); if b[i] == UInt8(ascii: ",") { i += 1; skip() }
            }
            i += 1
            return .array(items)
        case UInt8(ascii: "\""):
            let start = i
            i += 1
            while i < b.count, b[i] != UInt8(ascii: "\"") { i += b[i] == UInt8(ascii: "\\") ? 2 : 1 }
            i += 1
            let token = Data(b[start..<i])
            return (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String).map { .string($0) }
        case UInt8(ascii: "t"): i += 4; return .bool(true)
        case UInt8(ascii: "f"): i += 5; return .bool(false)
        case UInt8(ascii: "n"): i += 4; return .null
        default:
            let start = i
            while i < b.count, "+-.eE0123456789".utf8.contains(b[i]) { i += 1 }
            return .number(String(decoding: b[start..<i], as: UTF8.self))
        }
    }
}

// MARK: - String literals

enum Quote {
    /// POSIX shell single-quoted.
    static func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// PHP single-quoted: no interpolation, only `\\` and `\'` are escapes.
    static func php(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Double-quoted literal valid in JS, Python, Go and (with `swift: true`) Swift.
    static func dq(_ s: String, swift: Bool = false) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            case _ where u.value < 0x20 || u.value == 0x7F || u == "\u{2028}" || u == "\u{2029}":
                o += swift ? "\\u{\(String(u.value, radix: 16))}" : String(format: "\\u%04x", u.value)
            default: o.unicodeScalars.append(u)
            }
        }
        return o + "\""
    }

    /// Go raw string when possible (no backticks or CRs), otherwise interpreted.
    static func goRaw(_ s: String) -> String {
        s.contains("`") || s.contains("\r") ? dq(s) : "`" + s + "`"
    }

    /// Swift raw multi-line string for multi-line text, plain literal otherwise.
    static func swift(_ s: String) -> String {
        guard s.contains("\n"), !s.contains("\r") else { return dq(s, swift: true) }
        var h = "#"
        while s.contains("\"" + h) || s.contains("\\" + h) { h += "#" }
        return h + "\"\"\"\n" + s + "\n\"\"\"" + h
    }
}
