import Foundation

enum Curl {
    /// Shell-ish tokenizer: single/double quotes, $'ansi' quotes, backslash escapes and line continuations.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var inToken = false
        var quote: Character? = nil   // "'", "\"" or "$" (ANSI-C $'...')
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if q == "$" {
                    if c == "'" { quote = nil }
                    else if c == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": cur.append("\n")
                        case "t": cur.append("\t")
                        case "r": cur.append("\r")
                        default: cur.append(chars[i])
                        }
                    } else { cur.append(c) }
                } else if c == q {
                    quote = nil
                } else if c == "\\", q == "\"", i + 1 < chars.count {
                    i += 1
                    cur.append(chars[i])
                } else {
                    cur.append(c)
                }
            } else if c == "$", i + 1 < chars.count, chars[i + 1] == "'" {
                quote = "$"; inToken = true; i += 1
            } else if c == "'" || c == "\"" {
                quote = c; inToken = true
            } else if c == "\\", i + 1 < chars.count {
                i += 1
                // Treat "\<newline>" (and "\ " from mangled pastes) as a continuation.
                if !chars[i].isWhitespace { cur.append(chars[i]); inToken = true }
                else if inToken { tokens.append(cur); cur = ""; inToken = false }
            } else if c.isWhitespace {
                if inToken { tokens.append(cur); cur = ""; inToken = false }
            } else {
                cur.append(c); inToken = true
            }
            i += 1
        }
        if inToken { tokens.append(cur) }
        return tokens
    }

    static func parse(_ s: String) -> RequestSpec? {
        var t = tokenize(s.trimmingCharacters(in: .whitespacesAndNewlines))
        guard t.first == "curl" else { return nil }
        t.removeFirst()

        var spec = RequestSpec()
        var method: String?
        var data: [String] = []
        var forceGet = false
        var i = 0
        func next() -> String? { i += 1; return i < t.count ? t[i] : nil }
        func header(_ k: String, _ v: String) { spec.headers.append(KeyValue(key: k, value: v)) }

        while i < t.count {
            let a = t[i]
            switch a {
            case "-X", "--request": method = next()
            case "-H", "--header":
                if let h = next(), let idx = h.firstIndex(of: ":") {
                    header(h[..<idx].trimmingCharacters(in: .whitespaces),
                           h[h.index(after: idx)...].trimmingCharacters(in: .whitespaces))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode", "--json":
                if let d = next() { data.append(d) }
                if a == "--json" {
                    header("Content-Type", "application/json")
                    header("Accept", "application/json")
                }
            case "-u", "--user":
                if let u = next() {
                    let parts = u.split(separator: ":", maxSplits: 1).map(String.init)
                    spec.auth = Auth(kind: .basic, username: parts.first ?? "", password: parts.count > 1 ? parts[1] : "")
                }
            case "--url": if let u = next() { spec.url = u }
            case "-A", "--user-agent": if let v = next() { header("User-Agent", v) }
            case "-b", "--cookie": if let v = next() { header("Cookie", v) }
            case "-e", "--referer": if let v = next() { header("Referer", v) }
            case "-G", "--get": forceGet = true
            case "-o", "--output", "-m", "--max-time", "--connect-timeout", "-w", "--write-out",
                 "--retry", "-x", "--proxy", "--cacert", "--cert", "--key", "-F", "--form":
                _ = next()
            default:
                if a.hasPrefix("-X"), a.count > 2 { method = String(a.dropFirst(2)) }
                else if !a.hasPrefix("-"), spec.url.isEmpty { spec.url = a }
            }
            i += 1
        }
        guard !spec.url.isEmpty else { return nil }

        if forceGet, !data.isEmpty {
            let sep = spec.url.contains("?") ? "&" : "?"
            spec.url += sep + data.joined(separator: "&")
            data = []
        }
        if !data.isEmpty {
            let body = data.joined(separator: "&")
            let ct = spec.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let gql = graphQLParts(body) {
                spec.bodyKind = .graphql
                spec.body = gql.query
                spec.graphQLVariables = gql.variables
            } else if ct.contains("json") || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                spec.bodyKind = .json
                spec.body = JSONFormat.pretty(body) ?? body
            } else if ct.isEmpty || ct.contains("x-www-form-urlencoded") {
                spec.bodyKind = .form
                spec.form = body.split(separator: "&").map { pair in
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    return KeyValue(key: formDecode(kv[0]), value: kv.count > 1 ? formDecode(kv[1]) : "")
                }
                // Wisp adds this automatically for form bodies.
                spec.headers.removeAll { $0.key.lowercased() == "content-type" }
            } else {
                spec.bodyKind = .text
                spec.body = body
            }
        }
        spec.method = HTTPMethod(rawValue: (method ?? (data.isEmpty ? "GET" : "POST")).uppercased()) ?? .GET
        return spec
    }

    /// {"query": "...", "variables": {...}} → (query, pretty variables)
    static func graphQLParts(_ body: String) -> (query: String, variables: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let query = obj["query"] as? String,
              Set(obj.keys).isSubset(of: ["query", "variables", "operationName", "extensions"]) else { return nil }
        var vars = ""
        if let v = obj["variables"], !(v is NSNull),
           let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) {
            let s = String(decoding: d, as: UTF8.self)
            vars = JSONFormat.pretty(s) ?? s
        }
        return (GraphQL.format(query), vars)
    }

    private static func formDecode(_ s: String) -> String {
        let plus = s.replacingOccurrences(of: "+", with: " ")
        return plus.removingPercentEncoding ?? plus
    }

    static func export(_ req: URLRequest) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var parts = ["curl"]
        if let m = req.httpMethod, m != "GET" { parts.append("-X \(m)") }
        parts.append(q(req.url?.absoluteString ?? ""))
        for (k, v) in (req.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            parts.append("-H " + q("\(k): \(v)"))
        }
        if let b = req.httpBody, !b.isEmpty {
            parts.append("--data-raw " + q(String(decoding: b, as: UTF8.self)))
        }
        return parts.joined(separator: " \\\n  ")
    }
}
