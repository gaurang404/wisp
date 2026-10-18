import AppKit
import Network
import XCTest
@testable import Wisp

final class OAuthTests: XCTestCase {
    // MARK: JWT

    private func jwt(_ header: String, _ payload: String, sig: String = "c2ln") -> String {
        "\(OAuth.base64URL(Data(header.utf8))).\(OAuth.base64URL(Data(payload.utf8))).\(sig)"
    }

    func testJWTDecode() throws {
        let t = jwt(#"{"alg":"HS256","typ":"JWT"}"#, #"{"sub":"user-1","iss":"https://idp","exp":4102444800,"iat":1700000000,"name":"Zoë ?>"}"#)
        let info = try XCTUnwrap(JWT.decode("  Bearer \(t)\n"))
        XCTAssertEqual(info.subject, "user-1")
        XCTAssertEqual(info.issuer, "https://idp")
        XCTAssertEqual(info.expiresAt, Date(timeIntervalSince1970: 4102444800))
        XCTAssertEqual(info.issuedAt, Date(timeIntervalSince1970: 1700000000))
        XCTAssertFalse(info.isExpired)
        XCTAssertTrue(info.header.hasPrefix("{\n  \"alg\": \"HS256\""))
        XCTAssertTrue(info.payload.contains("\"name\": \"Zoë ?>\""))
        // Order preserved: sub before iss.
        XCTAssertLessThan(try XCTUnwrap(info.payload.range(of: "sub")).lowerBound, try XCTUnwrap(info.payload.range(of: "iss")).lowerBound)

        let expired = try XCTUnwrap(JWT.decode(jwt(#"{"alg":"none"}"#, #"{"exp":1000}"#, sig: "")))
        XCTAssertTrue(expired.isExpired)
        XCTAssertNil(JWT.decode("not.a.jwt"))
        XCTAssertNil(JWT.decode(jwt(#"{"typ":"JWT"}"#, "{}")))  // no alg
    }

    func testJWTFind() {
        let t = jwt(#"{"alg":"RS256"}"#, #"{"sub":"42"}"#, sig: "abc-_123")
        XCTAssertEqual(JWT.find(in: #"{"note":"v1.2.3","access_token":"\#(t)","x":1}"#), t)
        XCTAssertEqual(JWT.find(in: "Authorization: Bearer \(t)"), t)
        XCTAssertNil(JWT.find(in: "version 1.22.333 and www.example.com"))
    }

    // MARK: Pieces

    func testPKCEVectorRFC7636() {
        XCTAssertEqual(OAuth.pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(OAuth.randomURLSafe(32).count, 43)
    }

    func testFormEncoding() {
        XCTAssertEqual(OAuth.formEncode([("a b", "x+y&z=1"), ("scope", "read:all ü/~")]),
                       "a%20b=x%2By%26z%3D1&scope=read%3Aall%20%C3%BC%2F~")
        XCTAssertEqual(OAuth.formDecode("a=1+2&b=%2B%26&c"), ["a": "1 2", "b": "+&", "c": ""])
    }

    func testTokenRequestClientAuth() throws {
        var c = OAuthConfig()
        c.tokenURL = "https://idp.test/token"
        c.clientID = "my id"; c.clientSecret = "s:e+c"
        let r = try OAuth.makeTokenRequest(c, [("grant_type", "client_credentials")])
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("my%20id:s%3Ae%2Bc".utf8).base64EncodedString())
        XCTAssertEqual(r.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(String(decoding: r.httpBody!, as: UTF8.self), "grant_type=client_credentials")

        c.clientAuthInBody = true
        let r2 = try OAuth.makeTokenRequest(c, [("grant_type", "client_credentials")])
        XCTAssertNil(r2.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(String(decoding: r2.httpBody!, as: UTF8.self), "grant_type=client_credentials&client_id=my%20id&client_secret=s%3Ae%2Bc")
    }

    func testParseTokenResponse() throws {
        let json = Data(#"{"access_token":"AT","token_type":"bearer","expires_in":"3600","scope":"a b","id_token":"ID"}"#.utf8)
        let prev = OAuthToken(accessToken: "old", refreshToken: "RT-old")
        let t = try OAuth.parseTokenResponse(json, contentType: "application/json", previous: prev)
        XCTAssertEqual(t.accessToken, "AT")
        XCTAssertEqual(t.refreshToken, "RT-old")  // kept when omitted
        XCTAssertEqual(t.tokenType, "bearer")
        XCTAssertEqual(t.idToken, "ID")
        XCTAssertEqual(try XCTUnwrap(t.expiresAt).timeIntervalSinceNow, 3600, accuracy: 5)

        let form = Data("access_token=gho_x&scope=repo%2Cuser&token_type=bearer".utf8)
        let g = try OAuth.parseTokenResponse(form, contentType: "application/x-www-form-urlencoded", previous: nil)
        XCTAssertEqual(g.accessToken, "gho_x"); XCTAssertEqual(g.scope, "repo,user"); XCTAssertNil(g.expiresAt)

        XCTAssertThrowsError(try OAuth.parseTokenResponse(Data(#"{"error":"bad_verification_code","error_description":"The code is wrong"}"#.utf8),
                                                         contentType: "application/json", previous: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("bad_verification_code — The code is wrong"))
        }
        XCTAssertThrowsError(try OAuth.parseTokenResponse(Data("{}".utf8), contentType: "application/json", previous: nil))
    }

    // MARK: End-to-end against a local fake IdP

    func testAuthorizationCodeFlowEndToEnd() async throws {
        let server = try await FakeServer.start(port: 48712)
        defer { server.stop() }
        var challenge = ""
        server.handler = { req in
            let f = OAuth.formDecode(req.body)
            guard req.path == "/token", f["grant_type"] == "authorization_code", f["code"] == "CODE+1",
                  f["redirect_uri"] == "http://127.0.0.1:48713/cb", f["client_id"] == "wisp",
                  OAuth.pkceChallenge(f["code_verifier"] ?? "") == challenge
            else { return (400, #"{"error":"invalid_grant","error_description":"bad request \#(req.body)"}"#) }
            return (200, #"{"access_token":"AT-1","refresh_token":"RT-1","expires_in":120,"token_type":"Bearer"}"#)
        }
        let pages = Box()
        OAuth.openURL = { url in
            let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            challenge = q["code_challenge"] ?? ""
            XCTAssertEqual(q["code_challenge_method"], "S256")
            XCTAssertEqual(q["scope"], "openid profile")
            XCTAssertEqual(q["audience"], "api")
            XCTAssertEqual(q["keep"], "1")
            Task {
                let base = q["redirect_uri"]!
                let r404 = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:48713/favicon.ico")!).1
                pages.status404 = (r404 as? HTTPURLResponse)?.statusCode
                let d = try? await URLSession.shared.data(from: URL(string: base + "?code=CODE%2B1&state=\(q["state"]!)")!).0
                pages.html = String(decoding: d ?? Data(), as: UTF8.self)
            }
        }
        defer { OAuth.openURL = { NSWorkspace.shared.open($0) } }

        var c = OAuthConfig()
        c.authURL = "{{base}}/authorize?keep=1"
        c.tokenURL = "{{base}}/token"
        c.clientID = "wisp"
        c.scope = "openid profile"
        c.audience = "api"
        c.redirectURI = "http://127.0.0.1:48713/cb"
        let t = try await OAuth.fetchToken(c, resolve: Resolver(vars: ["base": "http://127.0.0.1:48712"]))
        XCTAssertEqual(t.accessToken, "AT-1")
        XCTAssertEqual(t.refreshToken, "RT-1")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(pages.status404, 404)
        XCTAssertTrue(pages.html.contains("Signed in to Wisp"))

        // Port is released afterwards: a second listener can bind.
        let again = try await FakeServer.start(port: 48713)
        again.stop()
    }

    func testAuthorizationErrorCallbackAndPortBusy() async throws {
        OAuth.openURL = { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            Task { _ = try? await URLSession.shared.data(from: URL(string: "http://localhost:48714/cb?error=access_denied&error_description=User%20said%20no&state=\(state)")!) }
        }
        defer { OAuth.openURL = { NSWorkspace.shared.open($0) } }
        var c = OAuthConfig()
        c.authURL = "http://127.0.0.1:1/authorize"; c.tokenURL = "http://127.0.0.1:1/token"; c.clientID = "x"
        c.redirectURI = "http://localhost:48714/cb"
        do { _ = try await OAuth.fetchToken(c, resolve: Resolver(vars: [:])); XCTFail("expected error") }
        catch { XCTAssertEqual(error.localizedDescription, "Authorization failed: access_denied — User said no") }

        let blocker = try await FakeServer.start(port: 48715)
        defer { blocker.stop() }
        c.redirectURI = "http://127.0.0.1:48715/cb"
        do { _ = try await OAuth.fetchToken(c, resolve: Resolver(vars: [:])); XCTFail("expected error") }
        catch { XCTAssertEqual(error.localizedDescription, "Port 48715 is busy — change the redirect URI") }
    }

    func testCancellationStopsListener() async throws {
        OAuth.openURL = { _ in }
        defer { OAuth.openURL = { NSWorkspace.shared.open($0) } }
        var c = OAuthConfig()
        c.authURL = "http://127.0.0.1:1/authorize"; c.tokenURL = "http://127.0.0.1:1/token"
        c.redirectURI = "http://127.0.0.1:48716/cb"
        let task = Task { try await OAuth.fetchToken(c, resolve: Resolver(vars: [:])) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let again = try await FakeServer.start(port: 48716)
        again.stop()
    }

    func testClientCredentialsAndRefresh() async throws {
        let server = try await FakeServer.start(port: 48717)
        defer { server.stop() }
        server.handler = { req in
            let f = OAuth.formDecode(req.body)
            switch f["grant_type"] {
            case "client_credentials":
                guard req.auth == "Basic " + Data("cid:p%40ss%2B".utf8).base64EncodedString(), f["scope"] == "a+b" else { return (401, #"{"error":"invalid_client"}"#) }
                return (200, #"{"access_token":"CC","refresh_token":"R1","expires_in":"1"}"#)
            case "refresh_token" where f["refresh_token"] == "R1":
                return (200, #"{"access_token":"CC2","expires_in":3600}"#)
            default:
                return (400, #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#)
            }
        }
        var c = OAuthConfig()
        c.grant = .clientCredentials
        c.tokenURL = "http://127.0.0.1:48717/token"
        c.clientID = "cid"; c.clientSecret = "{{secret}}"; c.scope = "a+b"
        let r = Resolver(vars: ["secret": "p@ss+"])
        let t = try await OAuth.fetchToken(c, resolve: r)
        XCTAssertEqual(t.accessToken, "CC")
        XCTAssertTrue(t.isExpired)  // expires in 1s, inside the 30s skew

        let v = try await OAuth.validToken(cached: t, config: c, resolve: r)
        XCTAssertEqual(v.accessToken, "CC2")
        XCTAssertEqual(v.refreshToken, "R1")
        let same = try await OAuth.validToken(cached: v, config: c, resolve: r)
        XCTAssertEqual(same, v)

        // Revoked refresh falls back to a fresh client-credentials token.
        var bad = t; bad.refreshToken = "revoked"
        let fresh = try await OAuth.validToken(cached: bad, config: c, resolve: r)
        XCTAssertEqual(fresh.accessToken, "CC")
        do { _ = try await OAuth.refresh(bad, config: c, resolve: r); XCTFail("expected error") }
        catch { XCTAssertEqual(error.localizedDescription, "Token request failed (HTTP 400): invalid_grant — Refresh token revoked") }
    }
}

private final class Box: @unchecked Sendable {
    var status404: Int?
    var html = ""
}

/// Minimal HTTP/1.1 server for tests: one request per connection, honours Content-Length.
private final class FakeServer: @unchecked Sendable {
    struct Request { var method = "", path = "", auth = "", body = "" }
    var handler: (Request) -> (Int, String) = { _ in (404, "{}") }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-idp")

    private init(_ l: NWListener) { listener = l }

    static func start(port: UInt16) async throws -> FakeServer {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let s = FakeServer(try NWListener(using: p))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Box()
            s.listener.stateUpdateHandler = { st in
                guard once.html.isEmpty else { return }
                switch st {
                case .ready: once.html = "done"; c.resume()
                case .failed(let e), .waiting(let e): once.html = "done"; c.resume(throwing: e)
                default: break
                }
            }
            s.listener.newConnectionHandler = { conn in conn.start(queue: s.queue); s.read(conn, Data()) }
            s.listener.start(queue: s.queue)
        }
        return s
    }

    func stop() { listener.cancel() }

    private func read(_ conn: NWConnection, _ buf: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, eof, _ in
            let buf = buf + (data ?? Data())
            guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return eof ? conn.cancel() : self.read(conn, buf) }
            let head = String(decoding: buf[..<sep.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            func header(_ n: String) -> String? {
                head.dropFirst().first { $0.lowercased().hasPrefix(n + ":") }.map { String($0.dropFirst(n.count + 1)).trimmingCharacters(in: .whitespaces) }
            }
            let length = Int(header("content-length") ?? "0") ?? 0
            let body = buf[sep.upperBound...]
            if body.count < length, !eof { return self.read(conn, buf) }
            let line = head[0].split(separator: " ")
            let req = Request(method: String(line[0]), path: String(line[1]), auth: header("authorization") ?? "", body: String(decoding: body, as: UTF8.self))
            let (status, json) = self.handler(req)
            let b = Data(json.utf8)
            let resp = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(b.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(resp.utf8) + b, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
