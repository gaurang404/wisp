import Foundation

struct KeyValue: Identifiable, Codable, Hashable {
    var id = UUID()
    var enabled = true
    var key = ""
    var value = ""
    /// Environment values marked secret are stored in the Keychain, not in state.json.
    var secret = false
}

enum HTTPMethod: String, CaseIterable, Codable, Identifiable {
    case GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS
    var id: String { rawValue }
}

enum BodyKind: String, CaseIterable, Codable, Identifiable {
    case none = "None", json = "JSON", graphql = "GraphQL", text = "Text", form = "Form"
    var id: String { rawValue }
}

enum AuthKind: String, CaseIterable, Codable, Identifiable {
    case none = "None", bearer = "Bearer", basic = "Basic", apiKey = "API Key", oauth2 = "OAuth 2"
    var id: String { rawValue }
}

enum APIKeyLocation: String, CaseIterable, Codable, Identifiable {
    case header = "Header", query = "Query"
    var id: String { rawValue }
}

enum OAuthGrant: String, CaseIterable, Codable, Identifiable {
    case authorizationCode = "Authorization Code", clientCredentials = "Client Credentials", password = "Password"
    var id: String { rawValue }
}

struct OAuthConfig: Codable, Hashable {
    var grant: OAuthGrant = .authorizationCode
    var authURL = ""
    var tokenURL = ""
    var clientID = ""
    var clientSecret = ""
    var scope = ""
    var audience = ""
    /// Loopback redirect for the authorization code flow; must be registered with the provider.
    var redirectURI = "http://127.0.0.1:53682/callback"
    var username = ""
    var password = ""
    /// Send client_id/secret in the form body instead of an HTTP Basic header.
    var clientAuthInBody = false

    /// Tokens are shared by every request using the same provider + client + scope.
    var cacheKey: String { [tokenURL, clientID, scope, audience, grant.rawValue].joined(separator: "|") }
}

struct OAuthToken: Codable, Hashable {
    var accessToken: String
    var refreshToken: String?
    var tokenType = "Bearer"
    var expiresAt: Date?
    var scope: String?
    var idToken: String?

    /// Treat as expired 30s early to avoid racing the server clock.
    var isExpired: Bool { expiresAt.map { $0.timeIntervalSinceNow < 30 } ?? false }
}

struct Auth: Codable, Hashable {
    var kind: AuthKind = .none
    var token = ""
    var username = ""
    var password = ""
    var apiKeyName = "X-API-Key"
    var apiKeyValue = ""
    var apiKeyIn: APIKeyLocation = .header
    var oauth = OAuthConfig()
}

struct RequestSpec: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var method: HTTPMethod = .GET
    var url = ""
    var params: [KeyValue] = []
    var headers: [KeyValue] = []
    var bodyKind: BodyKind = .none
    var body = ""
    var form: [KeyValue] = []
    var auth = Auth()
    /// GraphQL variables (JSON object text); the query lives in `body`.
    var graphQLVariables = ""
    /// Sidebar grouping; imports use the API title / tag.
    var folder = ""
    /// Markdown notes / documentation for this request.
    var docs = ""

    var displayName: String {
        if !name.isEmpty { return name }
        return url.isEmpty ? "Untitled" : url
    }

    /// "GET /users/42" style name derived from the URL.
    var suggestedName: String {
        let path = URLComponents(string: url)?.path ?? ""
        return "\(method.rawValue) \(path.isEmpty ? url : path)"
    }
}

struct EnvSet: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = "Default"
    var vars: [KeyValue] = []
    /// Applied to requests that have no auth of their own (e.g. "Bearer {{token}}" for every request to this API).
    var auth = Auth()
    /// Added to requests that don't already set the same header.
    var headers: [KeyValue] = []

    /// Host of this environment's {{baseUrl}}, used to pick the environment for a pasted URL.
    var host: String? {
        vars.first { $0.key == "baseUrl" && $0.enabled }.flatMap { URL(string: $0.value)?.host?.lowercased() }
    }
}

struct HistoryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var date = Date()
    var request: RequestSpec
    var status: Int?
    var duration: TimeInterval
}

struct Redirect: Hashable {
    var status: Int
    var from: URL
    var to: URL
}

struct ResponseData {
    var status: Int
    var headers: [(String, String)]
    var body: Data
    var duration: TimeInterval
    var url: URL?
    /// Pretty-printed body when JSON, nil otherwise.
    var prettyJSON: String?
    var text: String
    /// Redirect hops that were followed to get here (empty when none / not following).
    var redirects: [Redirect] = []

    var contentType: String {
        headers.first { $0.0.lowercased() == "content-type" }?.1 ?? ""
    }
    var isImage: Bool { contentType.lowercased().hasPrefix("image/") }
    /// Web page rather than API data — by content type, or by sniffing the start of the body.
    var isHTML: Bool {
        if contentType.lowercased().contains("html") { return true }
        guard prettyJSON == nil else { return false }
        let head = text.prefix(300).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }
    var location: String? { headers.first { $0.0.caseInsensitiveCompare("Location") == .orderedSame }?.1 }
    var headerText: String { headers.map { "\($0.0): \($0.1)" }.joined(separator: "\n") }
}

// MARK: - Lenient decoding (new fields must not break older state.json files)

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

extension HistoryEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        date = c.value(.date, Date())
        request = try c.decode(RequestSpec.self, forKey: .request)
        status = c.value(.status, nil)
        duration = c.value(.duration, 0)
    }
}

extension OAuthToken {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = c.value(.refreshToken, nil)
        tokenType = c.value(.tokenType, "Bearer")
        expiresAt = c.value(.expiresAt, nil)
        scope = c.value(.scope, nil)
        idToken = c.value(.idToken, nil)
    }
}

/// Decodes an array, skipping elements that fail (one bad entry must not make the whole file unreadable).
struct LossyArray<T: Decodable>: Decodable {
    var items: [T]
    private struct Skip: Decodable {}
    init(items: [T]) { self.items = items }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) } else { _ = try? c.decode(Skip.self) }
        }
        items = out
    }
}

extension EnvSet {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        name = c.value(.name, "Default")
        vars = c.value(.vars, [])
        auth = c.value(.auth, Auth())
        headers = c.value(.headers, [])
    }
}

extension KeyValue {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        enabled = c.value(.enabled, true)
        key = c.value(.key, "")
        value = c.value(.value, "")
        secret = c.value(.secret, false)
    }
}

extension RequestSpec {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RequestSpec()
        id = c.value(.id, d.id)
        name = c.value(.name, d.name)
        method = c.value(.method, d.method)
        url = c.value(.url, d.url)
        params = c.value(.params, d.params)
        headers = c.value(.headers, d.headers)
        bodyKind = c.value(.bodyKind, d.bodyKind)
        body = c.value(.body, d.body)
        form = c.value(.form, d.form)
        auth = c.value(.auth, d.auth)
        graphQLVariables = c.value(.graphQLVariables, d.graphQLVariables)
        folder = c.value(.folder, d.folder)
        docs = c.value(.docs, d.docs)
    }
}

extension Auth {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Auth()
        kind = c.value(.kind, d.kind)
        token = c.value(.token, d.token)
        username = c.value(.username, d.username)
        password = c.value(.password, d.password)
        apiKeyName = c.value(.apiKeyName, d.apiKeyName)
        apiKeyValue = c.value(.apiKeyValue, d.apiKeyValue)
        apiKeyIn = c.value(.apiKeyIn, d.apiKeyIn)
        oauth = c.value(.oauth, d.oauth)
    }
}

extension OAuthConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OAuthConfig()
        grant = c.value(.grant, d.grant)
        authURL = c.value(.authURL, d.authURL)
        tokenURL = c.value(.tokenURL, d.tokenURL)
        clientID = c.value(.clientID, d.clientID)
        clientSecret = c.value(.clientSecret, d.clientSecret)
        scope = c.value(.scope, d.scope)
        audience = c.value(.audience, d.audience)
        redirectURI = c.value(.redirectURI, d.redirectURI)
        username = c.value(.username, d.username)
        password = c.value(.password, d.password)
        clientAuthInBody = c.value(.clientAuthInBody, d.clientAuthInBody)
    }
}
