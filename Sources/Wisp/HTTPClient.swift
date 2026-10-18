import Foundation

enum RequestError: LocalizedError {
    case badURL(String)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "Invalid URL: \(s)"
        case .message(let s): return s
        }
    }
}

/// Replaces {{name}} / {{ name }} with environment values. Unknown vars are left as-is.
struct Resolver {
    let vars: [String: String]
    private static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_.\-]+)\s*\}\}"#)

    func callAsFunction(_ s: String) -> String {
        guard s.contains("{{"), !vars.isEmpty else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in Self.pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let key = ns.substring(with: m.range(at: 1))
            out += vars[key] ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}

enum HTTPClient {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.httpShouldSetCookies = false
        // An API client must always hit the server — never answer from a local HTTP cache.
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c)
    }()

    /// `oauthToken` is the already-acquired access token when `spec.auth.kind == .oauth2`.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Wisp/\(version) (macOS)"
    }()

    static func build(_ spec: RequestSpec, vars: [String: String], oauthToken: OAuthToken? = nil) throws -> URLRequest {
        let r = Resolver(vars: vars)
        var raw = r(spec.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw RequestError.badURL("(empty)") }
        if !raw.contains("://") {
            let local = raw.hasPrefix("localhost") || raw.hasPrefix("127.") || raw.hasPrefix("0.0.0.0")
            raw = (local ? "http://" : "https://") + raw
        }
        guard var comps = URLComponents(string: raw) else { throw RequestError.badURL(raw) }
        let extra = spec.params
            .filter { $0.enabled && !$0.key.isEmpty }
            .map { URLQueryItem(name: r($0.key), value: r($0.value)) }
        var query = extra
        if spec.auth.kind == .apiKey, spec.auth.apiKeyIn == .query, !spec.auth.apiKeyName.isEmpty {
            query.append(URLQueryItem(name: r(spec.auth.apiKeyName), value: r(spec.auth.apiKeyValue)))
        }
        if !query.isEmpty {
            // Encode ourselves: URLComponents leaves "+" alone, which servers read as a space.
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=#"))
            let encoded = query.map {
                ($0.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.name) + "="
                    + (($0.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            }.joined(separator: "&")
            let existing = comps.percentEncodedQuery ?? ""
            comps.percentEncodedQuery = existing.isEmpty ? encoded : existing + "&" + encoded
        }
        guard let url = comps.url, url.host != nil else { throw RequestError.badURL(raw) }

        var req = URLRequest(url: url)
        req.httpMethod = spec.method.rawValue
        for h in spec.headers where h.enabled && !h.key.isEmpty {
            if r(h.key).caseInsensitiveCompare("User-Agent") == .orderedSame {
                req.setValue(r(h.value), forHTTPHeaderField: "User-Agent")   // replaces the default
            } else {
                req.addValue(r(h.value), forHTTPHeaderField: r(h.key))
            }
        }
        switch spec.auth.kind {
        case .none: break
        case .bearer:
            req.setValue("Bearer \(r(spec.auth.token))", forHTTPHeaderField: "Authorization")
        case .basic:
            let cred = Data("\(r(spec.auth.username)):\(r(spec.auth.password))".utf8).base64EncodedString()
            req.setValue("Basic \(cred)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            if spec.auth.apiKeyIn == .header, !spec.auth.apiKeyName.isEmpty {
                req.setValue(r(spec.auth.apiKeyValue), forHTTPHeaderField: r(spec.auth.apiKeyName))
            }
        case .oauth2:
            if let t = oauthToken {
                let type = t.tokenType.lowercased() == "bearer" || t.tokenType.isEmpty ? "Bearer" : t.tokenType
                req.setValue("\(type) \(t.accessToken)", forHTTPHeaderField: "Authorization")
            }
        }

        func defaultContentType(_ v: String) {
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue(v, forHTTPHeaderField: "Content-Type")
            }
        }
        switch spec.bodyKind {
        case .none: break
        case .json:
            req.httpBody = Data(r(spec.body).utf8)
            defaultContentType("application/json")
        case .graphql:
            req.httpBody = Data(GraphQL.requestBody(query: r(spec.body), variables: r(spec.graphQLVariables)).utf8)
            defaultContentType("application/json")
            if req.value(forHTTPHeaderField: "Accept") == nil {
                req.setValue("application/graphql-response+json, application/json", forHTTPHeaderField: "Accept")
            }
        case .text:
            req.httpBody = Data(r(spec.body).utf8)
            defaultContentType("text/plain; charset=utf-8")
        case .form:
            var c = URLComponents()
            c.queryItems = spec.form
                .filter { $0.enabled && !$0.key.isEmpty }
                .map { URLQueryItem(name: r($0.key), value: r($0.value)) }
            let encoded = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
            req.httpBody = Data(encoded.utf8)
            defaultContentType("application/x-www-form-urlencoded")
        }
        return req
    }

    /// Records each redirect hop; returning nil stops at the 3xx response instead of following it.
    private final class RedirectRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let follow: Bool
        var hops: [Redirect] = []
        init(follow: Bool) { self.follow = follow }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard follow else { return completionHandler(nil) }
            if let from = response.url, let to = request.url {
                hops.append(Redirect(status: response.statusCode, from: from, to: to))
            }
            // Credentials must not follow a redirect to another host or from https to http.
            var next = request
            let crossHost = response.url?.host?.lowercased() != request.url?.host?.lowercased()
            let downgrade = response.url?.scheme == "https" && request.url?.scheme == "http"
            if crossHost || downgrade {
                for name in (next.allHTTPHeaderFields ?? [:]).keys
                where name.lowercased() == "cookie" || DocsExport.isSecret(name) {
                    next.setValue(nil, forHTTPHeaderField: name)
                }
            }
            completionHandler(next)
        }
    }

    /// Runs off the main actor; formatting of the body happens here too.
    static func send(_ req: URLRequest, followRedirects: Bool = true) async throws -> ResponseData {
        let start = Date()
        var req = req
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")   // only on the wire — never in exported code
        }
        let recorder = RedirectRecorder(follow: followRedirects)
        let (data, resp) = try await session.data(for: req, delegate: recorder)
        let duration = Date().timeIntervalSince(start)
        let http = resp as? HTTPURLResponse
        let headers = (http?.allHeaderFields ?? [:])
            .map { ("\($0.key)", "\($0.value)") }
            .sorted { $0.0.lowercased() < $1.0.lowercased() }
        let text = String(decoding: data, as: UTF8.self)
        return ResponseData(
            status: http?.statusCode ?? 0,
            headers: headers,
            body: data,
            duration: duration,
            url: http?.url,
            prettyJSON: JSONFormat.pretty(text),
            text: text,
            redirects: recorder.hops
        )
    }
}
