import Foundation

// Generic, provider-free smarts: make a request reusable, follow pagination, explain auth challenges.

// MARK: - Save credentials & base URL

/// "Save credentials & base URL": turn a one-off request (e.g. a pasted cURL with a token) into a reusable one.
struct ReusableResult {
    /// URL rewritten to "{{baseUrl}}/rest?query"; literal credentials removed (the environment supplies them).
    var spec: RequestSpec
    var host: String
    var baseURL: String
    /// baseUrl first (not secret), then credential variables (secret, literal values).
    var variables: [KeyValue]
    /// Templated auth the environment applies to requests without their own auth.
    var envAuth: Auth
    /// Extra credential headers ("{{var}}") when the request carried more than one credential.
    var envHeaders: [KeyValue]
    /// Literal secret → "{{var}}", used to scrub history.
    var replacements: [String: String]
}

enum Reusable {
    /// scheme://host[:port] + leading API-prefix path segments (api, rest, admin, v1, 2026-10, …).
    static func apiBase(of url: URL) -> String {
        split(url.absoluteString).map { $0.origin + $0.apiPrefix } ?? url.absoluteString
    }

    static func hasLiteralCredentials(_ spec: RequestSpec) -> Bool {
        let a = spec.auth
        switch a.kind {
        case .bearer where isLiteral(a.token): return true
        case .basic where isLiteral(a.username) || isLiteral(a.password): return true
        case .apiKey where isLiteral(a.apiKeyValue): return true
        default: break
        }
        if spec.headers.contains(where: { $0.enabled && isSecretHeader($0.key) && isLiteral($0.value) }) { return true }
        if spec.params.contains(where: { $0.enabled && isSecretQuery($0.key) && isLiteral($0.value) }) { return true }
        if let s = split(spec.url), s.userinfo != nil { return true }
        return Query.items(Query.of(spec.url)).contains { isSecretQuery($0.name) && isLiteral($0.value) }
    }

    static func make(_ spec: RequestSpec, vars: [String: String]) -> ReusableResult? {
        let original = spec.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let templated = original.hasPrefix("{{baseUrl}}")
        if templated && !hasLiteralCredentials(spec) { return nil }
        var resolved = Resolver(vars: vars)(original)
        if !resolved.contains("://") { resolved = "https://" + resolved }
        guard let r = split(resolved), ["http", "https"].contains(r.scheme), !r.host.isEmpty, r.host.rangeOfCharacter(from: CharacterSet(charactersIn: "{} \t")) == nil else { return nil }

        var out = spec
        var names: Set<String> = ["baseUrl"]
        var variables = [KeyValue(key: "baseUrl", value: r.origin + r.apiPrefix)]
        var replacements: [String: String] = [:]
        var envAuth: Auth?
        var envHeaders: [KeyValue] = []

        /// Registers a secret variable and returns "{{name}}" (or "" for an empty value).
        func variable(_ base: String, _ value: String) -> String {
            guard !value.isEmpty else { return "" }
            var name = base.isEmpty ? "token" : base, n = 2
            while names.contains(name) { name = base + String(n); n += 1 }
            names.insert(name)
            variables.append(KeyValue(key: name, value: value, secret: true))
            replacements[value] = "{{\(name)}}"
            return "{{\(name)}}"
        }
        func apiKey(_ name: String, _ value: String, _ location: APIKeyLocation) -> Auth {
            Auth(kind: .apiKey, apiKeyName: name, apiKeyValue: value, apiKeyIn: location)
        }
        func basic(_ user: String, _ pass: String) -> Auth {
            Auth(kind: .basic, username: variable("username", user), password: variable("password", pass))
        }
        func authorization(_ value: String) -> Auth {
            let parts = value.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return apiKey("Authorization", variable("apiKey", value), .header) }
            let scheme = parts[0], cred = parts[1].trimmingCharacters(in: .whitespaces)
            switch scheme.lowercased() {
            case "bearer": return Auth(kind: .bearer, token: variable("token", cred))
            case "basic":
                if let d = Data(base64Encoded: cred), let s = String(data: d, encoding: .utf8), let c = s.firstIndex(of: ":") {
                    return basic(String(s[..<c]), String(s[s.index(after: c)...]))
                }
                fallthrough
            default: return apiKey("Authorization", "\(scheme) \(variable("token", cred))", .header)
            }
        }

        // 1. Auth tab, then an Authorization header (ignored when the auth tab already supplies one).
        let a = spec.auth
        switch a.kind {
        case .bearer where isLiteral(a.token): envAuth = Auth(kind: .bearer, token: variable("token", a.token))
        case .basic where isLiteral(a.username) || isLiteral(a.password): envAuth = basic(a.username, a.password)
        case .apiKey where isLiteral(a.apiKeyValue):
            envAuth = apiKey(a.apiKeyName, variable(camel(a.apiKeyName), a.apiKeyValue), a.apiKeyIn)
        default: break
        }
        if envAuth != nil { out.auth = Auth() }
        if let i = out.headers.firstIndex(where: { $0.enabled && $0.key.caseInsensitiveCompare("Authorization") == .orderedSame && isLiteral($0.value) }) {
            if envAuth == nil { envAuth = authorization(out.headers[i].value) }
            out.headers.remove(at: i)
        }
        if envAuth == nil, let info = r.userinfo {
            let p = info.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map { $0.removingPercentEncoding ?? String($0) }
            envAuth = basic(p[0], p.count > 1 ? p[1] : "")
        }
        // 2. Credential headers: the first becomes envAuth (if none yet), the rest shared env headers.
        out.headers = out.headers.filter { h in
            guard h.enabled, isSecretHeader(h.key), isLiteral(h.value) else { return true }
            let v = variable(camel(h.key), h.value)
            if envAuth == nil { envAuth = apiKey(h.key, v, .header) } else { envHeaders.append(KeyValue(key: h.key, value: v)) }
            return false
        }
        // 3. Credential query params (URL, then params): first may become envAuth; the rest stay templated.
        var query: [Query.Item] = []
        for item in Query.items(Query.of(original)) {
            guard isSecretQuery(item.name), isLiteral(item.value) else { query.append(item); continue }
            let v = variable(camel(item.name), item.value)
            if envAuth == nil { envAuth = apiKey(item.name, v, .query) } else { query.append(Query.Item(name: item.name, raw: "\(item.name)=\(v)")) }
        }
        out.params = out.params.compactMap { p in
            guard p.enabled, isSecretQuery(p.key), isLiteral(p.value) else { return p }
            let v = variable(camel(p.key), p.value)
            if envAuth == nil { envAuth = apiKey(p.key, v, .query); return nil }
            var t = p; t.value = v; return t
        }

        // Rewrite the URL: drop origin + API prefix, keep everything else ({{vars}} included) verbatim.
        let fragment = original.firstIndex(of: "#").map { String(original[$0...]) } ?? ""
        var rest = Query.base(original)
        if templated {
            rest.removeFirst("{{baseUrl}}".count)
        } else if let o = split(original.contains("://") ? original : "https://" + original) {
            rest = o.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst(1 + r.prefixCount)
                .map { "/" + $0 }.joined()
        }
        out.url = "{{baseUrl}}" + rest + (query.isEmpty ? "" : "?" + query.map(\.raw).joined(separator: "&")) + fragment

        let baseURL = templated ? (vars["baseUrl"] ?? variables[0].value) : variables[0].value
        variables[0].value = baseURL
        return ReusableResult(spec: out, host: r.host, baseURL: baseURL, variables: variables,
                              envAuth: envAuth ?? Auth(), envHeaders: envHeaders, replacements: replacements)
    }

    // MARK: Helpers

    private static func isLiteral(_ s: String) -> Bool { !s.isEmpty && !s.contains("{{") }

    private static let notSecret: Set<String> = ["content-type", "accept", "user-agent", "x-request-id", "idempotency-key"]
    private static func isSecretHeader(_ name: String) -> Bool {
        let n = name.lowercased()
        guard !notSecret.contains(n) else { return false }
        return ["token", "secret", "api-key", "apikey", "api_key", "auth", "password", "session"].contains { n.contains($0) }
    }
    private static let secretQuery: Set<String> = ["api_key", "apikey", "access_token", "token", "key", "client_secret", "secret"]
    private static func isSecretQuery(_ name: String) -> Bool { secretQuery.contains(name.lowercased()) }

    /// "X-Shopify-Access-Token" → "shopifyAccessToken", "api_key" → "apiKey".
    private static func camel(_ name: String) -> String {
        var words = name.split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() }
        if words.count > 1, words[0] == "x" { words.removeFirst() }
        guard let first = words.first else { return "token" }
        return first + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    private struct Parts {
        var scheme: String, userinfo: String?, host: String, origin: String, path: String
        var apiPrefix: String, prefixCount: Int
    }

    /// String-level URL split (tolerates {{vars}} anywhere after the authority).
    private static func split(_ url: String) -> Parts? {
        guard let sep = url.range(of: "://") else { return nil }
        let scheme = url[..<sep.lowerBound].lowercased()
        let afterScheme = url[sep.upperBound...]
        let authEnd = afterScheme.firstIndex { "/?#".contains($0) } ?? afterScheme.endIndex
        var authority = String(afterScheme[..<authEnd])
        var userinfo: String?
        if let at = authority.lastIndex(of: "@") {
            userinfo = String(authority[..<at])
            authority = String(authority[authority.index(after: at)...])
        }
        let host = String(authority.prefix { $0 != ":" }).lowercased()
        let path = Query.base(String(afterScheme[authEnd...]))
        var prefix = "", count = 0
        for seg in path.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            guard isAPISegment(String(seg)) else { break }
            prefix += "/" + seg; count += 1
        }
        let origin = scheme + "://" + host + String(authority.drop { $0 != ":" })
        return Parts(scheme: scheme, userinfo: userinfo, host: host, origin: origin, path: path, apiPrefix: prefix, prefixCount: count)
    }

    private static let apiSegment = try! NSRegularExpression(
        pattern: #"^(api|rest|admin|webapi|wp-json|wc|unstable|v\d+(\.\d+)?|\d{4}-\d{2}(-\d{2})?)$"#, options: .caseInsensitive)
    private static func isAPISegment(_ s: String) -> Bool {
        apiSegment.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

// MARK: - Pagination

enum Paging {
    static func nextPage(for spec: RequestSpec, resolvedURL: URL?, status: Int, headers: [(String, String)], body: Data) -> RequestSpec? {
        guard (200..<300).contains(status) else { return nil }
        var out = spec

        // 1. RFC 8288 Link header.
        if let link = headers.first(where: { $0.0.caseInsensitiveCompare("Link") == .orderedSame })?.1,
           let next = nextLink(link, relativeTo: resolvedURL) {
            return follow(next, spec, resolvedURL)
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }

        // 2. A next-page URL in the body.
        let urlKeys = ["next", "next_page_url", "nextPageUrl", "next_url", "nextUrl", "nextLink", "@odata.nextLink"]
        if let raw = find(urlKeys, in: json)?.0 {
            if raw.hasPrefix("?") {
                let items = Query.items(Query.of(raw))
                out.url = Query.upserting(items, into: spec.url)
                let names = Set(items.map(\.name))
                out.params = spec.params.map { var p = $0; if names.contains(p.key) { p.enabled = false }; return p }
                return out
            }
            if raw.lowercased().hasPrefix("http") || raw.hasPrefix("/"), let next = URL(string: raw, relativeTo: resolvedURL)?.absoluteURL,
               next.host != nil {
                return follow(next, spec, resolvedURL)
            }
        }

        // 3. Cursor tokens.
        let cursorParams = [("next_cursor", "cursor"), ("nextCursor", "cursor"), ("nextPageCursor", "cursor"),
                            ("next_page_token", "page_token"), ("nextPageToken", "pageToken")]
        if let hit = find(cursorParams.map(\.0), in: json, skipWhenDone: true),
           let param = cursorParams.first(where: { $0.0 == hit.1 })?.1 {
            Query.setParam(&out, param, hit.0)
            return out
        }

        // 4. Stripe list shape.
        if json["has_more"] as? Bool == true, let id = (json["data"] as? [[String: Any]])?.last?["id"] as? String {
            Query.setParam(&out, "starting_after", id, removing: ["ending_before"])
            return out
        }

        // 5. Page numbers (Laravel meta or top level).
        let meta = json["meta"] as? [String: Any] ?? json
        if let current = (meta["current_page"] as? NSNumber)?.intValue, let last = (meta["last_page"] as? NSNumber)?.intValue, current < last {
            Query.setParam(&out, "page", String(current + 1))
            return out
        }
        return nil
    }

    /// RFC 8288: `<url>; rel="next", <url>; rel="last"`.
    static func nextLink(_ header: String, relativeTo base: URL?) -> URL? {
        let rx = try! NSRegularExpression(pattern: #"<([^>]*)>([^<]*)"#)
        let ns = header as NSString
        for m in rx.matches(in: header, range: NSRange(location: 0, length: ns.length)) {
            let params = ns.substring(with: m.range(at: 2))
            guard let r = params.range(of: #"rel\s*=\s*("[^"]*"|[^;,\s]+)"#, options: [.regularExpression, .caseInsensitive]) else { continue }
            let rels = params[r].split(separator: "=", maxSplits: 1).last?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased().split(separator: " ") ?? []
            if rels.contains("next") { return URL(string: ns.substring(with: m.range(at: 1)), relativeTo: base)?.absoluteURL }
        }
        return nil
    }

    /// Same host + path → keep the (templated) base and swap the query; otherwise use the absolute URL. Params are disabled.
    private static func follow(_ next: URL, _ spec: RequestSpec, _ current: URL?) -> RequestSpec {
        var out = spec
        if let current, current.host?.lowercased() == next.host?.lowercased(), current.path == next.path {
            let query = URLComponents(url: next, resolvingAgainstBaseURL: true)?.percentEncodedQuery ?? ""
            out.url = Query.base(spec.url) + (query.isEmpty ? "" : "?" + query)
        } else {
            out.url = next.absoluteString
        }
        out.params = spec.params.map { var p = $0; p.enabled = false; return p }
        return out
    }

    /// Breadth-first search (objects only, depth ≤ 3) for the first non-empty string under one of `keys`.
    private static func find(_ keys: [String], in root: [String: Any], skipWhenDone: Bool = false) -> (String, String)? {
        var level = [root]
        for _ in 0...3 {
            var nextLevel: [[String: Any]] = []
            for obj in level {
                let done = ["has_more", "hasNextPage", "has_next_page"].contains { obj[$0] as? Bool == false }
                if !(skipWhenDone && done) {
                    for k in keys { if let s = obj[k] as? String, !s.isEmpty { return (s, k) } }
                }
                nextLevel += obj.keys.sorted().compactMap { obj[$0] as? [String: Any] }
            }
            level = nextLevel
        }
        return nil
    }
}

// MARK: - Auth challenges

/// What auth a 401/407 response asks for, in plain words.
struct AuthHint: Equatable {
    var kind: AuthKind
    var title: String
    var detail: String

    static func from(status: Int, headers: [(String, String)], requestAuth: AuthKind) -> AuthHint? {
        guard status == 401 || status == 407 else { return nil }
        let headerName = status == 407 ? "Proxy-Authenticate" : "WWW-Authenticate"
        let raw = headers.filter { $0.0.caseInsensitiveCompare(headerName) == .orderedSame }.map(\.1).joined(separator: ", ")
        let challenges = parse(raw)
        let rejected = requestAuth != .none
        let who = status == 407 ? "This proxy" : "This API"
        let pick = challenges.first { $0.scheme == "bearer" } ?? challenges.first { $0.scheme == "basic" } ?? challenges.first
        guard let c = pick else {
            return rejected
                ? AuthHint(kind: .bearer, title: "The credentials were rejected", detail: "Check the token or key is correct, not expired, and meant for this API.")
                : AuthHint(kind: .bearer, title: "\(who) needs authentication", detail: "Most APIs take a Bearer token or an API key header — check the API docs.")
        }
        let realm = c.params["realm"].map { " (realm “\($0)”)" } ?? ""
        let description = c.params["error_description"].map { " The server says: \($0)." } ?? ""
        switch c.scheme {
        case "bearer":
            if c.params["error"] == "invalid_token" || rejected {
                return AuthHint(kind: .bearer, title: "The token was rejected",
                                detail: "The Bearer token\(realm) is invalid, expired, or revoked.\(description)")
            }
            let scope = c.params["scope"].map { " Required scope: \($0)." } ?? ""
            return AuthHint(kind: .bearer, title: "\(who) wants a Bearer token",
                            detail: "Set Auth to Bearer and paste a token\(realm).\(description)\(scope)")
        case "basic":
            return rejected
                ? AuthHint(kind: .basic, title: "The username or password was rejected", detail: "Check the Basic auth credentials\(realm).")
                : AuthHint(kind: .basic, title: "\(who) wants a username and password",
                           detail: "Set Auth to Basic and enter the username and password\(realm).")
        case "digest", "negotiate", "ntlm", "kerberos":
            let name = c.scheme == "ntlm" ? "NTLM" : c.scheme.capitalized
            return AuthHint(kind: .apiKey, title: "\(who) uses \(name) auth, which Wisp doesn't support yet",
                            detail: "Try a token or API key instead if the API offers one\(realm).")
        default:
            return AuthHint(kind: .apiKey, title: rejected ? "The credentials were rejected" : "\(who) wants a “\(c.original)” credential",
                            detail: "Send it as an Authorization: \(c.original) <key> header (Auth → API Key)\(realm).\(description)")
        }
    }

    private struct Challenge { var scheme: String; var original: String; var params: [String: String] = [:] }

    /// `Bearer realm="a", error="invalid_token", Basic realm="b"` → challenges with their auth-params.
    private static func parse(_ header: String) -> [Challenge] {
        var parts: [String] = [], cur = "", quoted = false
        for ch in header {
            if ch == "\"" { quoted.toggle() }
            if ch == ",", !quoted { parts.append(cur); cur = "" } else { cur.append(ch) }
        }
        parts.append(cur)
        var out: [Challenge] = []
        for var part in parts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let first = part.prefix { !$0.isWhitespace && $0 != "=" }
            let afterFirst = part.dropFirst(first.count).drop { $0.isWhitespace }
            if !afterFirst.hasPrefix("=") {   // a new scheme, optionally followed by its first param
                out.append(Challenge(scheme: first.lowercased(), original: String(first)))
                part = String(afterFirst)
                if part.isEmpty { continue }
            }
            guard !out.isEmpty, let eq = part.firstIndex(of: "=") else { continue }
            let name = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            out[out.count - 1].params[name] = value
        }
        return out
    }
}

// MARK: - String-level query helpers (spec URLs may contain {{vars}} that URLComponents can't parse)

private enum Query {
    struct Item { var name: String; var raw: String
        var value: String { let v = raw.drop { $0 != "=" }.dropFirst(); return String(v).removingPercentEncoding ?? String(v) }
    }

    static func base(_ url: String) -> String { String(url.prefix { $0 != "?" && $0 != "#" }) }

    static func of(_ url: String) -> Substring {
        guard let q = url.firstIndex(of: "?") else { return "" }
        return url[url.index(after: q)...].prefix { $0 != "#" }
    }

    static func items(_ query: Substring) -> [Item] {
        query.split(separator: "&").map { raw in
            let name = raw.prefix { $0 != "=" }
            return Item(name: String(name).removingPercentEncoding ?? String(name), raw: String(raw))
        }
    }

    /// Replaces items with the same name in place, appends the rest; other items are kept.
    static func upserting(_ items: [Item], into url: String) -> String {
        var existing = Self.items(of(url))
        for item in items {
            if let i = existing.firstIndex(where: { $0.name == item.name }) { existing[i] = item } else { existing.append(item) }
        }
        return base(url) + (existing.isEmpty ? "" : "?" + existing.map(\.raw).joined(separator: "&"))
    }

    /// Sets an enabled param, removing that key (and `removing`) from both the URL query and params.
    static func setParam(_ spec: inout RequestSpec, _ key: String, _ value: String, removing: Set<String> = []) {
        let drop = removing.union([key])
        let kept = items(of(spec.url)).filter { !drop.contains($0.name) }
        spec.url = base(spec.url) + (kept.isEmpty ? "" : "?" + kept.map(\.raw).joined(separator: "&"))
        spec.params.removeAll { drop.contains($0.key) }
        spec.params.append(KeyValue(key: key, value: value))
    }
}
