import AppKit
import CryptoKit
import Foundation
import Network

enum OAuthError: LocalizedError {
    case invalidURL(field: String, value: String)
    case invalidRedirect(String)
    case portBusy(Int)
    case listenerFailed(String)
    case timedOut
    case stateMismatch
    case authorizationDenied(error: String, description: String?)
    case tokenRequestFailed(status: Int, error: String?, description: String?, body: String)
    case invalidTokenResponse(String)
    case noRefreshToken

    var errorDescription: String? {
        switch self {
        case .invalidURL(let field, let value):
            return "Invalid \(field): \(value.isEmpty ? "(empty)" : value)"
        case .invalidRedirect(let s):
            return "Redirect URI must be a loopback http URL like http://127.0.0.1:53682/callback (got \(s.isEmpty ? "(empty)" : s))"
        case .portBusy(let p):
            return "Port \(p) is busy — change the redirect URI"
        case .listenerFailed(let s):
            return "Couldn't start the local callback listener: \(s)"
        case .timedOut:
            return "Timed out waiting for the browser sign-in"
        case .stateMismatch:
            return "OAuth state mismatch — the callback didn't come from this sign-in attempt"
        case .authorizationDenied(let e, let d):
            return "Authorization failed: \(e)" + (d.map { " — \($0)" } ?? "")
        case .tokenRequestFailed(let status, let e, let d, let body):
            if let e { return "Token request failed (HTTP \(status)): \(e)" + (d.map { " — \($0)" } ?? "") }
            let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            return "Token request failed (HTTP \(status))" + (snippet.isEmpty ? "" : ": \(snippet)")
        case .invalidTokenResponse(let s):
            return "Unexpected token response: \(s)"
        case .noRefreshToken:
            return "No refresh token available"
        }
    }
}

enum OAuth {
    /// Injectable for tests.
    static var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    static var callbackTimeout: TimeInterval = 180

    static func fetchToken(_ config: OAuthConfig, resolve: Resolver) async throws -> OAuthToken {
        let c = resolved(config, resolve)
        switch c.grant {
        case .clientCredentials:
            return try await tokenRequest(c, [("grant_type", "client_credentials")] + scopeAudience(c), previous: nil)
        case .password:
            return try await tokenRequest(c, [("grant_type", "password"), ("username", c.username), ("password", c.password)]
                                          + scopeAudience(c), previous: nil)
        case .authorizationCode:
            return try await authorizationCode(c)
        }
    }

    static func refresh(_ token: OAuthToken, config: OAuthConfig, resolve: Resolver) async throws -> OAuthToken {
        guard let rt = token.refreshToken, !rt.isEmpty else { throw OAuthError.noRefreshToken }
        return try await tokenRequest(resolved(config, resolve), [("grant_type", "refresh_token"), ("refresh_token", rt)], previous: token)
    }

    static func validToken(cached: OAuthToken?, config: OAuthConfig, resolve: Resolver) async throws -> OAuthToken {
        if let cached, !cached.isExpired { return cached }
        if let cached, cached.refreshToken?.isEmpty == false {
            do { return try await refresh(cached, config: config, resolve: resolve) }
            catch is CancellationError { throw CancellationError() }
            catch {}
        }
        return try await fetchToken(config, resolve: resolve)
    }

    // MARK: - Authorization code + PKCE

    private static func authorizationCode(_ c: OAuthConfig) async throws -> OAuthToken {
        guard var auth = URLComponents(string: c.authURL), auth.host != nil else {
            throw OAuthError.invalidURL(field: "authorization URL", value: c.authURL)
        }
        guard let redirect = URL(string: c.redirectURI), redirect.scheme?.lowercased() == "http",
              let host = redirect.host?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host)
        else { throw OAuthError.invalidRedirect(c.redirectURI) }

        let verifier = randomURLSafe(32), state = randomURLSafe(16)
        var q: [(String, String)] = [("response_type", "code"), ("client_id", c.clientID), ("redirect_uri", c.redirectURI)]
        if !c.scope.isEmpty { q.append(("scope", c.scope)) }
        q += [("state", state), ("code_challenge", pkceChallenge(verifier)), ("code_challenge_method", "S256")]
        if !c.audience.isEmpty { q.append(("audience", c.audience)) }
        auth.percentEncodedQuery = [auth.percentEncodedQuery, formEncode(q)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "&")
        guard let authURL = auth.url else { throw OAuthError.invalidURL(field: "authorization URL", value: c.authURL) }

        let path = redirect.path.isEmpty ? "/" : redirect.path
        let server = LoopbackServer(host: host, port: redirect.port ?? 80, path: path, state: state)
        defer { server.cancel() }
        try await server.start()
        try Task.checkCancellation()
        await MainActor.run { openURL(authURL) }
        let code = try await server.waitForCode(timeout: callbackTimeout)
        server.cancel()

        var body = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", c.redirectURI), ("code_verifier", verifier)]
        if !c.audience.isEmpty { body.append(("audience", c.audience)) }
        return try await tokenRequest(c, body, previous: nil)
    }

    static func pkceChallenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &g) }))
    }

    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Token endpoint

    private static func resolved(_ c: OAuthConfig, _ r: Resolver) -> OAuthConfig {
        var c = c
        for kp in [\OAuthConfig.authURL, \.tokenURL, \.redirectURI] { c[keyPath: kp] = r(c[keyPath: kp]).trimmingCharacters(in: .whitespacesAndNewlines) }
        for kp in [\OAuthConfig.clientID, \.clientSecret, \.scope, \.audience, \.username, \.password] { c[keyPath: kp] = r(c[keyPath: kp]) }
        return c
    }

    private static func scopeAudience(_ c: OAuthConfig) -> [(String, String)] {
        (c.scope.isEmpty ? [] : [("scope", c.scope)]) + (c.audience.isEmpty ? [] : [("audience", c.audience)])
    }

    /// Unreserved chars only (RFC 3986); everything else, including '+', '&', '=', space, is percent-encoded.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func percentEncode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }

    static func formEncode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    static func formDecode(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func dec(_ x: Substring) -> String { String(x).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(x) }
            if let k = kv.first { out[dec(k)] = kv.count > 1 ? dec(kv[1]) : "" }
        }
        return out
    }

    static func makeTokenRequest(_ c: OAuthConfig, _ params: [(String, String)]) throws -> URLRequest {
        guard let url = URL(string: c.tokenURL), url.host != nil else { throw OAuthError.invalidURL(field: "token URL", value: c.tokenURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var body = params
        if c.clientAuthInBody || c.clientSecret.isEmpty {
            if !c.clientID.isEmpty { body.append(("client_id", c.clientID)) }
            if !c.clientSecret.isEmpty { body.append(("client_secret", c.clientSecret)) }
        } else {
            let cred = "\(percentEncode(c.clientID)):\(percentEncode(c.clientSecret))"  // RFC 6749 §2.3.1
            req.setValue("Basic \(Data(cred.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = Data(formEncode(body).utf8)
        return req
    }

    private static func tokenRequest(_ c: OAuthConfig, _ params: [(String, String)], previous: OAuthToken?) async throws -> OAuthToken {
        let (data, resp) = try await HTTPClient.session.data(for: makeTokenRequest(c, params))
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let type = http?.value(forHTTPHeaderField: "Content-Type")
        guard (200..<300).contains(status) else {
            let f = fields(data, contentType: type)
            throw OAuthError.tokenRequestFailed(status: status, error: f["error"] as? String,
                                                description: f["error_description"] as? String, body: String(decoding: data, as: UTF8.self))
        }
        return try parseTokenResponse(data, contentType: type, previous: previous, status: status)
    }

    private static func fields(_ data: Data, contentType: String?) -> [String: Any] {
        if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return o }
        let text = String(decoding: data, as: UTF8.self)
        if contentType?.lowercased().contains("json") != true, text.contains("=") { return formDecode(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return [:]
    }

    static func parseTokenResponse(_ data: Data, contentType: String?, previous: OAuthToken?, status: Int = 200) throws -> OAuthToken {
        let f = fields(data, contentType: contentType)
        func str(_ k: String) -> String? {
            switch f[k] {
            case let s as String: return s.isEmpty ? nil : s
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }
        if let e = str("error") {  // e.g. GitHub answers 200 with an error body
            throw OAuthError.tokenRequestFailed(status: status, error: e, description: str("error_description"), body: String(decoding: data, as: UTF8.self))
        }
        guard let access = str("access_token") else {
            let snippet = String(decoding: data.prefix(300), as: UTF8.self)
            throw OAuthError.invalidTokenResponse(snippet.isEmpty ? "empty body" : "no access_token in \(snippet)")
        }
        var t = OAuthToken(accessToken: access)
        t.refreshToken = str("refresh_token") ?? previous?.refreshToken
        t.tokenType = str("token_type") ?? "Bearer"
        t.expiresAt = str("expires_in").flatMap(Double.init).map { Date().addingTimeInterval($0) }
        t.scope = str("scope") ?? previous?.scope
        t.idToken = str("id_token") ?? previous?.idToken
        return t
    }
}

// MARK: - Loopback redirect listener

/// One-shot HTTP listener for the redirect. All mutable state lives on `queue`.
private final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wisp.oauth.loopback")
    private let host: String, port: Int, path: String, state: String
    private var listener: NWListener?
    private var ready: CheckedContinuation<Void, Error>?
    private var waiter: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    init(host: String, port: Int, path: String, state: String) {
        (self.host, self.port, self.path, self.state) = (host, port, path, state)
    }

    func start() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else { throw OAuthError.invalidRedirect("port \(port)") }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        let l: NWListener
        do {
            if host == "localhost" {
                l = try NWListener(using: params, on: nwPort)  // browsers may pick ::1 or 127.0.0.1; non-loopback peers are dropped
            } else {
                params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
                l = try NWListener(using: params)
            }
        } catch { throw map(error) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                listener = l
                ready = c
                l.stateUpdateHandler = { [weak self] s in self?.listenerState(s) }
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.start(queue: queue)
            }
        }
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                queue.async { [self] in
                    if let result { return c.resume(with: result) }
                    waiter = c
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(OAuthError.timedOut)) }
                }
            }
        } onCancel: { queue.async { self.finish(.failure(CancellationError())) } }
    }

    func cancel() { queue.async { [self] in listener?.cancel(); listener = nil } }

    private func map(_ e: Error) -> Error {
        if case .posix(let code) = e as? NWError, code == .EADDRINUSE { return OAuthError.portBusy(port) }
        if case .posix(let code) = e as? NWError, code == .EADDRNOTAVAIL { return OAuthError.invalidRedirect("\(host):\(port)") }
        return OAuthError.listenerFailed(e.localizedDescription)
    }

    private func listenerState(_ s: NWListener.State) {
        switch s {
        case .ready: ready?.resume(); ready = nil
        case .failed(let e), .waiting(let e):
            if let r = ready { r.resume(throwing: map(e)); ready = nil } else { finish(.failure(map(e))) }
            listener?.cancel()
        case .cancelled:
            ready?.resume(throwing: CancellationError()); ready = nil
        default: break
        }
    }

    private func finish(_ r: Result<String, Error>) {
        guard result == nil else { return }
        result = r
        waiter?.resume(with: r); waiter = nil
    }

    private func accept(_ conn: NWConnection) {
        if case .hostPort(let h, _) = conn.endpoint, !Self.isLoopback(h) { return conn.cancel() }
        conn.start(queue: queue)
        receive(conn, Data())
    }

    private static func isLoopback(_ h: NWEndpoint.Host) -> Bool {
        switch h {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    private func receive(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, err in
            guard let self else { return conn.cancel() }
            let buf = buffer + (data ?? Data())
            if buf.range(of: Data("\r\n\r\n".utf8)) != nil || buf.range(of: Data("\n\n".utf8)) != nil || done || err != nil || buf.count > 65_536 {
                handle(conn, String(decoding: buf, as: UTF8.self))
            } else { receive(conn, buf) }
        }
    }

    private func handle(_ conn: NWConnection, _ request: String) {
        let parts = request.prefix { $0 != "\r" && $0 != "\n" }.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: "http://x" + parts[1]),
              comps.path == path, result == nil
        else { return reply(conn, 404, "Not found") }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if q["state"] != state {
            // Ignore a stray error-free hit without state (e.g. a prefetch); treat a wrong state as fatal.
            if q["state"] == nil, q["code"] == nil, q["error"] == nil { return reply(conn, 404, "Not found") }
            reply(conn, 400, page("Sign-in failed", "The response didn't match this sign-in attempt. Return to Wisp and try again."))
            return finish(.failure(OAuthError.stateMismatch))
        }
        if let e = q["error"] {
            reply(conn, 400, page("Sign-in failed", "\(e)\(q["error_description"].map { ": \($0)" } ?? ""). Return to Wisp and try again."))
            return finish(.failure(OAuthError.authorizationDenied(error: e, description: q["error_description"])))
        }
        guard let code = q["code"], !code.isEmpty else {
            reply(conn, 400, page("Sign-in failed", "No authorization code was returned."))
            return finish(.failure(OAuthError.authorizationDenied(error: "missing code", description: nil)))
        }
        reply(conn, 200, page("Signed in to Wisp", "You can close this tab and return to Wisp."))
        finish(.success(code))
    }

    private func page(_ title: String, _ message: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title><style>body{font:16px -apple-system,system-ui,sans-serif;\
        display:flex;height:90vh;align-items:center;justify-content:center;color:#333;background:#fafafa}div{text-align:center}h1{font-weight:600}\
        </style></head><body><div><h1>\(esc(title))</h1><p>\(esc(message))</p></div></body></html>
        """
    }

    private func reply(_ conn: NWConnection, _ status: Int, _ body: String) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "OK"
        let b = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(b.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + b, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }
}
