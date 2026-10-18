import AppKit
import Observation

@Observable @MainActor
final class Store {
    var saved: [RequestSpec] = []
    var history: [HistoryEntry] = []
    var envs: [EnvSet] = [EnvSet()] { didSet { scheduleSave() } }
    var activeEnvID: UUID?
    var current = RequestSpec() { didSet { scheduleSave() } }
    var response: ResponseData?
    var error: String?
    var isSending = false
    var toast: String?
    /// Human-readable progress while a request waits on something (e.g. OAuth sign-in in the browser).
    var status: String?
    /// OAuth tokens keyed by OAuthConfig.cacheKey — shared by all requests of the same API.
    var tokens: [String: OAuthToken] = [:]
    var sheet: Sheet?
    /// Follow 3xx redirects (like a browser). Off = show the redirect response itself.
    var followRedirects: Bool = UserDefaults.standard.object(forKey: "followRedirects") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followRedirects, forKey: "followRedirects") }
    }

    // GraphQL schemas, keyed by resolved endpoint URL (in memory only).
    var schemas: [String: GQLSchema] = [:]
    var schemaLoading = false
    var schemaError: String?

    enum Sheet: Identifiable {
        case code, importer, environments, jwt(String), graphQLBuilder
        var id: String {
            switch self {
            case .graphQLBuilder: "graphQLBuilder"
            case .code: "code"
            case .importer: "importer"
            case .environments: "environments"
            case .jwt(let t): "jwt:\(t)"
            }
        }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sendID = UUID()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    private static let historyLimit = 200

    private struct Persisted: Codable {
        var saved: [RequestSpec]
        var history: [HistoryEntry]
        var envs: [EnvSet]
        var activeEnvID: UUID?
        var current: RequestSpec?
        var tokens: [String: OAuthToken]?

        init(saved: [RequestSpec], history: [HistoryEntry], envs: [EnvSet], activeEnvID: UUID?,
             current: RequestSpec?, tokens: [String: OAuthToken]?) {
            self.saved = saved; self.history = history; self.envs = envs
            self.activeEnvID = activeEnvID; self.current = current; self.tokens = tokens
        }

        /// One bad entry (or a field from a future version) must not make the whole file unreadable.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            saved = c.value(.saved, LossyArray<RequestSpec>(items: [])).items
            history = c.value(.history, LossyArray<HistoryEntry>(items: [])).items
            envs = c.value(.envs, LossyArray<EnvSet>(items: [])).items
            activeEnvID = c.value(.activeEnvID, nil)
            current = c.value(.current, nil)
            tokens = c.value(.tokens, nil)
        }
    }

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    init() {
        load()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persist() }
        }
    }

    var activeVars: [String: String] {
        guard let env = envs.first(where: { $0.id == activeEnvID }) else { return [:] }
        return Dictionary(env.vars.filter { $0.enabled && !$0.key.isEmpty }.map { ($0.key, $0.value) },
                          uniquingKeysWith: { _, b in b })
    }

    var isSaved: Bool { saved.contains { $0.id == current.id } }

    // MARK: - Sending

    func send() {
        task?.cancel()
        error = nil
        page = 1
        let original = current
        let spec = effective(current)
        let vars = activeVars
        let follow = followRedirects
        if spec.auth.kind != .oauth2 {
            // Fail fast on bad URLs before spinning up a task.
            do { _ = try HTTPClient.build(spec, vars: vars) } catch {
                self.error = error.localizedDescription
                response = nil
                return
            }
        }
        let id = UUID()
        sendID = id
        isSending = true
        task = Task {
            defer { if sendID == id { isSending = false; status = nil } }
            do {
                var token: OAuthToken?
                if spec.auth.kind == .oauth2 {
                    token = try await oauthToken(for: spec.auth.oauth, vars: vars)
                    guard sendID == id else { return }
                }
                let req = try HTTPClient.build(spec, vars: vars, oauthToken: token)
                let r = try await HTTPClient.send(req, followRedirects: follow)
                guard sendID == id else { return }
                response = r
                record(original, status: r.status, duration: r.duration)
            } catch {
                guard sendID == id, !Task.isCancelled else { return }
                if (error as? URLError)?.code == .cancelled { return }
                self.error = error.localizedDescription
                response = nil
                record(original, status: nil, duration: 0)
            }
        }
    }

    // MARK: - OAuth

    /// Cached → refreshed → freshly fetched (may open the browser). Updates the shared cache.
    func oauthToken(for config: OAuthConfig, vars: [String: String], forceNew: Bool = false) async throws -> OAuthToken {
        let key = tokenKey(config, vars: vars)
        let cached = forceNew ? nil : tokens[key]
        if let cached, !cached.isExpired { return cached }
        if let inFlight = tokenFetches[key] { return try await inFlight.value }   // e.g. schema load + send at once
        // Fail fast instead of waiting on a browser sign-in that can never complete.
        let r = Resolver(vars: vars)
        func valid(_ s: String) -> Bool { URL(string: r(s).trimmingCharacters(in: .whitespaces))?.host != nil }
        guard valid(config.tokenURL) else {
            throw RequestError.message("OAuth isn't fully set up — add the Token URL in the Auth tab.")
        }
        if config.grant == .authorizationCode, !valid(config.authURL) {
            throw RequestError.message("OAuth isn't fully set up — add the Authorize URL in the Auth tab.")
        }
        status = config.grant == .authorizationCode && cached?.refreshToken == nil
            ? "Waiting for sign-in in your browser…" : "Fetching access token…"
        let fetch = Task { try await OAuth.validToken(cached: cached, config: config, resolve: Resolver(vars: vars)) }
        tokenFetches[key] = fetch
        defer { tokenFetches[key] = nil }
        let token = try await fetch.value
        tokens[key] = token
        persist()
        return token
    }

    @ObservationIgnored private var tokenFetches: [String: Task<OAuthToken, Error>] = [:]

    /// Tokens are cached per *resolved* provider/client/scope — {{tokenUrl}} in Staging vs Prod must not share a token.
    func tokenKey(_ c: OAuthConfig, vars: [String: String]) -> String {
        let r = Resolver(vars: vars)
        return [r(c.tokenURL), r(c.clientID), r(c.scope), r(c.audience), c.grant.rawValue].joined(separator: "|")
    }

    func getNewToken() {
        let config = effective(current).auth.oauth
        let vars = activeVars
        task?.cancel()
        let id = UUID()
        sendID = id
        isSending = true
        error = nil
        task = Task {
            defer { if sendID == id { isSending = false; status = nil } }
            do {
                _ = try await oauthToken(for: config, vars: vars, forceNew: true)
                flash("Got a new access token")
            } catch {
                guard sendID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func clearToken() {
        tokens[tokenKey(effective(current).auth.oauth, vars: activeVars)] = nil
        persist()
        flash("Token cleared")
    }

    var currentToken: OAuthToken? { tokens[tokenKey(effective(current).auth.oauth, vars: activeVars)] }

    // MARK: - Environments that know their API (generic — works for any host)

    /// URLs whose "save credentials" hint was dismissed this session.
    var dismissedHints: Set<String> = []
    /// 1-based page number of the current result when walking pages with "Next page".
    var page = 1
    /// Ask the request pane to show a tab (e.g. "Auth" from a 401 hint).
    var focusRequestTab: String?

    var activeEnv: EnvSet? { envs.first { $0.id == activeEnvID } }

    /// The request as it will be sent: it inherits the environment's auth and headers when it has none of its own.
    func effective(_ spec: RequestSpec) -> RequestSpec {
        guard let env = activeEnv, applies(env, to: spec) else { return spec }
        var s = spec
        if s.auth.kind == .none, env.auth.kind != .none { s.auth = env.auth }
        let present = Set(s.headers.filter { $0.enabled && !$0.key.isEmpty }.map { $0.key.lowercased() })
        s.headers += env.headers.filter { $0.enabled && !$0.key.isEmpty && !present.contains($0.key.lowercased()) }
        return s
    }

    /// An environment's default auth/headers go only to its own API host — never to other hosts.
    func applies(_ env: EnvSet, to spec: RequestSpec) -> Bool {
        guard let envHost = env.host else { return false }
        let resolved = Resolver(vars: activeVars)(spec.url).trimmingCharacters(in: .whitespaces)
        return URL(string: resolved)?.host?.lowercased() == envHost
    }

    /// Host the current URL points at (resolved with the active environment).
    var currentHost: String? {
        URL(string: Resolver(vars: activeVars)(current.url).trimmingCharacters(in: .whitespaces))?.host?.lowercased()
    }

    /// Called when the URL changes: pick the environment saved for this host, and switch GraphQL endpoints to GraphQL.
    func urlChanged() {
        if let host = currentHost, activeEnv?.host != host {
            let matches = envs.filter { $0.host == host }
            if matches.count == 1, let env = matches.first {
                activeEnvID = env.id
                persist()
                flash("Using \(env.name)")
            } else if matches.count > 1, lastAmbiguousHost != host {
                lastAmbiguousHost = host
                flash("Several environments use \(host) — pick one in the toolbar")
            }
        }
        let path = URL(string: current.url)?.path.lowercased() ?? ""
        if current.bodyKind == .none, path.hasSuffix("/graphql") || path.hasSuffix("graphql.json") {
            useGraphQL(query: "", variables: "")
        }
    }

    @ObservationIgnored private var lastAmbiguousHost: String?

    /// Show "save credentials" when the request carries literal secrets (e.g. a pasted cURL with a token).
    var canMakeReusable: Bool {
        !dismissedHints.contains(current.url) && Reusable.hasLiteralCredentials(current) && currentHost != nil
    }

    /// Moves literal credentials into Keychain-backed variables of the host's environment, sets {{baseUrl}},
    /// makes the environment supply the auth, and scrubs the secrets from history.
    func makeReusable() {
        guard let r = Reusable.make(current, vars: activeVars) else { return }
        let host = r.host.lowercased()
        // Prefer the active environment; otherwise the single one for this host; never guess between several.
        let i: Int
        if let a = envs.firstIndex(where: { $0.id == activeEnvID }), envs[a].host == host {
            i = a
        } else {
            let matches = envs.indices.filter { envs[$0].host == host }
            if matches.count > 1 { flash("Several environments use \(host) — pick one in the toolbar first"); return }
            if let only = matches.first {
                i = only
            } else {
                envs.append(EnvSet(name: r.host))
                i = envs.count - 1
            }
        }
        // Literal credential headers that the environment now supplies are dropped from history and saved requests too.
        let kept = Set(r.spec.headers.map { $0.key.lowercased() })
        for h in current.headers where h.enabled && !h.value.contains("{{") && !kept.contains(h.key.lowercased()) {
            removedHeaderValues.insert(h.value)
        }
        var spec = r.spec
        var variables = r.variables
        // An existing {{baseUrl}} wins: rewrite this request relative to it instead of changing it for every saved request.
        if let existing = envs[i].vars.first(where: { $0.key == "baseUrl" && $0.enabled && !$0.value.isEmpty })?.value,
           spec.url.hasPrefix("{{baseUrl}}") {
            let literal = r.baseURL + spec.url.dropFirst("{{baseUrl}}".count)
            spec.url = literal.hasPrefix(existing) ? "{{baseUrl}}" + literal.dropFirst(existing.count) : literal
            variables.removeAll { $0.key == "baseUrl" }
        }
        for v in variables {
            if let j = envs[i].vars.firstIndex(where: { $0.key == v.key }) {
                envs[i].vars[j].value = v.value
                envs[i].vars[j].secret = envs[i].vars[j].secret || v.secret
                envs[i].vars[j].enabled = true
            } else {
                envs[i].vars.append(v)
            }
        }
        if r.envAuth.kind != .none { envs[i].auth = r.envAuth }
        for h in r.envHeaders where !envs[i].headers.contains(where: { $0.key.caseInsensitiveCompare(h.key) == .orderedSame }) {
            envs[i].headers.append(h)
        }
        activeEnvID = envs[i].id
        if let k = saved.firstIndex(where: { $0.id == current.id }) { saved[k] = spec }
        current = spec
        scrub(r.replacements)
        persist()
        flash("Saved for \(envs[i].name) — secrets are in the Keychain")
    }

    /// "Use this auth for every request to this API": moves the request's auth to the environment.
    func shareAuthWithEnvironment() {
        guard let i = envs.firstIndex(where: { $0.id == activeEnvID }) else { return }
        // Scope the environment to this API so its auth is never sent elsewhere.
        if envs[i].host == nil,
           let url = URL(string: Resolver(vars: activeVars)(current.url).trimmingCharacters(in: .whitespaces)), url.host != nil {
            envs[i].vars.insert(KeyValue(key: "baseUrl", value: Reusable.apiBase(of: url)), at: 0)
        }
        var replacements: [String: String] = [:]
        func secretVar(_ name: String, _ value: String) -> String {
            guard !value.isEmpty, !value.contains("{{") else { return value }
            var key = name
            var n = 2
            while let existing = envs[i].vars.first(where: { $0.key == key }), existing.value != value { key = "\(name)\(n)"; n += 1 }
            if !envs[i].vars.contains(where: { $0.key == key }) { envs[i].vars.append(KeyValue(key: key, value: value, secret: true)) }
            replacements[value] = "{{\(key)}}"
            return "{{\(key)}}"
        }
        var auth = current.auth
        switch auth.kind {
        case .bearer: auth.token = secretVar("token", auth.token)
        case .basic: auth.password = secretVar("password", auth.password)
        case .apiKey: auth.apiKeyValue = secretVar("apiKey", auth.apiKeyValue)
        case .oauth2:
            auth.oauth.clientSecret = secretVar("clientSecret", auth.oauth.clientSecret)
            auth.oauth.password = secretVar("oauthPassword", auth.oauth.password)
        case .none: break
        }
        envs[i].auth = auth
        current.auth = Auth()
        if let k = saved.firstIndex(where: { $0.id == current.id }) { saved[k] = current }
        scrub(replacements)
        persist()
        flash("\(envs[i].name) now supplies this auth — secrets are in the Keychain")
    }

    /// Secret → {{variable}} for credentials moved into the Keychain this session (also catches requests in flight).
    @ObservationIgnored private var scrubbedSecrets: [String: String] = [:]   // substring replacements (≥ 8 chars)
    @ObservationIgnored private var exactSecrets: [String: String] = [:]      // whole-field replacements (any length)
    @ObservationIgnored private var removedHeaderValues: Set<String> = []

    private func scrub(_ replacements: [String: String]) {
        let encodings: [CharacterSet] = [.alphanumerics, CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=#"))]
        for (secret, variable) in replacements where !secret.isEmpty {
            exactSecrets[secret] = variable
            guard secret.count >= 8 else { continue }   // short values (e.g. "admin") would match unrelated text
            scrubbedSecrets[secret] = variable
            for set in encodings {
                if let enc = secret.addingPercentEncoding(withAllowedCharacters: set), enc != secret { scrubbedSecrets[enc] = variable }
            }
        }
        for i in history.indices { history[i].request = scrubbed(history[i].request) }
        for i in saved.indices { saved[i] = scrubbed(saved[i]) }
    }

    private func scrubbed(_ spec: RequestSpec) -> RequestSpec {
        guard !scrubbedSecrets.isEmpty || !exactSecrets.isEmpty || !removedHeaderValues.isEmpty else { return spec }
        func scrub(_ s: String) -> String {
            if let exact = exactSecrets[s] { return exact }
            return scrubbedSecrets.reduce(s) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }
        var r = spec
        r.headers.removeAll { removedHeaderValues.contains($0.value) }
        for h in r.headers.indices { r.headers[h].value = scrub(r.headers[h].value) }
        for p in r.params.indices { r.params[p].value = scrub(r.params[p].value) }
        r.url = scrub(r.url)
        r.auth.token = scrub(r.auth.token)
        r.auth.apiKeyValue = scrub(r.auth.apiKeyValue)
        r.auth.username = scrub(r.auth.username)
        r.auth.password = scrub(r.auth.password)
        r.auth.oauth.clientSecret = scrub(r.auth.oauth.clientSecret)
        r.auth.oauth.password = scrub(r.auth.oauth.password)
        return r
    }

    /// Next-page URLs sometimes echo the API key back in their query — never copy that into the request.
    private func withoutSecretQuery(_ spec: RequestSpec) -> RequestSpec {
        let eff = effective(current)
        var names: Set<String> = ["api_key", "apikey", "access_token", "client_secret", "secret", "password"]
        if eff.auth.kind == .apiKey, eff.auth.apiKeyIn == .query { names.insert(eff.auth.apiKeyName.lowercased()) }
        guard let q = spec.url.firstIndex(of: "?") else { return spec }
        let items = spec.url[spec.url.index(after: q)...].split(separator: "&").filter { item in
            let name = String(item.prefix { $0 != "=" })
            return !names.contains((name.removingPercentEncoding ?? name).lowercased())
        }
        var out = spec
        out.url = String(spec.url[..<q]) + (items.isEmpty ? "" : "?" + items.joined(separator: "&"))
        return out
    }

    func loadNextPage() {
        guard let r = response,
              let next = Paging.nextPage(for: current, resolvedURL: r.url, status: r.status, headers: r.headers, body: r.body)
        else { return }
        current = withoutSecretQuery(next)
        let p = page
        send()
        page = p + 1
    }

    var hasNextPage: Bool {
        guard let r = response else { return false }
        return Paging.nextPage(for: current, resolvedURL: r.url, status: r.status, headers: r.headers, body: r.body) != nil
    }

    // MARK: - GraphQL

    /// Resolved endpoint of the current request — the key schemas are cached under.
    var endpointKey: String? {
        (try? HTTPClient.build(current, vars: activeVars))?.url?.absoluteString
    }

    var currentSchema: GQLSchema? { endpointKey.flatMap { schemas[$0] } }

    /// Fetches the schema via introspection, reusing the current request's URL, headers and auth.
    func loadSchema(force: Bool = false, auto: Bool = false) async {
        guard let key = endpointKey else {
            schemaError = "Enter the GraphQL endpoint URL first."
            return
        }
        if !force, schemas[key] != nil { return }
        var spec = effective(current)
        if auto, spec.auth.kind == .oauth2, currentToken == nil { return }
        spec.method = .POST
        spec.bodyKind = .graphql
        spec.body = GraphQL.introspectionQuery
        spec.graphQLVariables = ""
        let vars = activeVars
        schemaLoading = true
        schemaError = nil
        defer { schemaLoading = false }
        do {
            var token: OAuthToken?
            if spec.auth.kind == .oauth2 { token = try await oauthToken(for: spec.auth.oauth, vars: vars) }
            let r = try await HTTPClient.send(try HTTPClient.build(spec, vars: vars, oauthToken: token))
            guard (200..<300).contains(r.status) || GraphQL.looksLikeGraphQLResponse(r.body) else {
                throw RequestError.message("\(r.status) \(reasonPhrase(r.status)) — is this a GraphQL endpoint? Check the URL and auth.")
            }
            schemas[key] = try GraphQL.parseSchema(r.body)
        } catch {
            schemaError = error.localizedDescription
        }
    }

    func useGraphQL(query: String, variables: String) {
        current.bodyKind = .graphql
        current.body = query
        current.graphQLVariables = variables
        if current.method == .GET { current.method = .POST }
    }

    /// One-click demo against a public, auth-free GraphQL API.
    func tryGraphQLDemo() {
        var spec = RequestSpec()
        spec.name = "Countries (GraphQL demo)"
        spec.method = .POST
        spec.url = "https://countries.trevorblades.com/"
        spec.bodyKind = .graphql
        spec.body = """
        query GetCountry($code: ID!) {
          country(code: $code) {
            name
            capital
            emoji
            currency
            languages {
              name
            }
          }
        }
        """
        spec.graphQLVariables = "{\n  \"code\": \"IN\"\n}"
        open(spec)
        send()
        Task { await loadSchema() }
    }

    // MARK: - Variables

    /// Sets `{{name}}` in the active environment (creating/activating one if needed).
    func setVariable(_ name: String, _ value: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if activeEnvID == nil || !envs.contains(where: { $0.id == activeEnvID }) {
            if envs.isEmpty { envs.append(EnvSet()) }
            activeEnvID = envs[0].id
        }
        let i = envs.firstIndex { $0.id == activeEnvID }!
        if let j = envs[i].vars.firstIndex(where: { $0.key == name }) {
            envs[i].vars[j].value = value
            envs[i].vars[j].enabled = true
        } else {
            envs[i].vars.append(KeyValue(key: name, value: value, secret: DocsExport.isSecret(name)))
        }
        persist()
        flash("Saved as {{\(name)}} in \(envs[i].name)")
    }

    // MARK: - Import / export

    func importData(_ data: Data) {
        do {
            apply(try Importer.parse(data))
        } catch {
            flash(error.localizedDescription)
        }
    }

    /// Imports from a spec URL *or a docs page* (finds the OpenAPI/Swagger spec behind it).
    /// The import creates an environment with {{baseUrl}}, so later URLs for that host pick it automatically.
    /// Returns an error message, or nil on success.
    @discardableResult
    func importFromURL(_ string: String) async -> String? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            return "Not a valid URL"
        }
        status = "Looking for the API spec…"
        defer { status = nil }
        do {
            let found = try await SpecDiscovery.discover(url)
            var result = found.result
            let specURL = found.specURL
            // Specs with a relative server ("/api/v3") import as http://localhost…; rebase onto where the spec lives.
            if let host = specURL.host, let scheme = specURL.scheme,
               let i = result.variables.firstIndex(where: { $0.key == "baseUrl" }) {
                let v = result.variables[i].value
                if v == "http://localhost" || v.hasPrefix("http://localhost/") {
                    let origin = "\(scheme)://\(host)" + (specURL.port.map { ":\($0)" } ?? "")
                    result.variables[i].value = origin + v.dropFirst("http://localhost".count)
                }
            }
            apply(result)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func apply(_ result: ImportResult) {
        guard !result.requests.isEmpty else { flash("Nothing to import"); return }
        saved.append(contentsOf: result.requests)
        if !result.variables.isEmpty {
            // Merge into an environment named after the API; never overwrite values the user already set.
            let envName = result.name.isEmpty ? "Imported" : result.name
            if let i = envs.firstIndex(where: { $0.name == envName }) {
                for v in result.variables where !envs[i].vars.contains(where: { $0.key == v.key }) {
                    envs[i].vars.append(v)
                }
                activeEnvID = envs[i].id
            } else {
                let env = EnvSet(name: envName, vars: result.variables)
                envs.append(env)
                activeEnvID = env.id
            }
        }
        if let first = result.requests.first { open(first) }
        persist()
        flash("Imported \(result.requests.count) request\(result.requests.count == 1 ? "" : "s") · \(result.format)")
    }

    func exportDocs(folder: String? = nil) {
        let requests = folder.map { f in saved.filter { $0.folder == f || $0.folder.hasPrefix(f + "/") } } ?? saved
        guard !requests.isEmpty else { flash("Nothing to export"); return }
        let title = folder.flatMap { $0.isEmpty ? nil : $0 } ?? "API Reference"
        var vars = activeVars
        for v in activeEnv?.vars ?? [] where v.secret { vars[v.key] = "•••" }
        let md = DocsExport.markdown(title: title, requests: requests, vars: vars)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? Data(md.utf8).write(to: url)
            flash("Exported docs")
        }
    }

    func deleteFolder(_ folder: String) {
        saved.removeAll { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }
        persist()
    }

    func builtRequest() throws -> URLRequest {
        let spec = effective(current)
        return try HTTPClient.build(spec, vars: activeVars, oauthToken: spec.auth.kind == .oauth2 ? currentToken : nil)
    }

    func cancel() {
        sendID = UUID()
        task?.cancel()
        isSending = false
        status = nil
    }

    private func record(_ spec: RequestSpec, status: Int?, duration: TimeInterval) {
        history.insert(HistoryEntry(request: scrubbed(spec), status: status, duration: duration), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        persist()
    }

    // MARK: - Requests

    func newRequest() {
        current = RequestSpec()
        response = nil
        error = nil
    }

    func open(_ spec: RequestSpec) {
        current = spec
        response = nil
        error = nil
    }

    func save() {
        if current.name.isEmpty { current.name = current.suggestedName }
        if let i = saved.firstIndex(where: { $0.id == current.id }) {
            saved[i] = current
        } else {
            saved.append(current)
        }
        persist()
        flash("Saved")
    }

    func moveToFolder(_ spec: RequestSpec, _ folder: String) {
        guard let i = saved.firstIndex(where: { $0.id == spec.id }) else { return }
        saved[i].folder = folder
        if current.id == spec.id { current.folder = folder }
        persist()
    }

    func duplicate(_ spec: RequestSpec) {
        var dup = spec
        dup.id = UUID()
        dup.name = spec.displayName + " copy"
        saved.append(dup)
        open(dup)
        persist()
    }

    func delete(_ spec: RequestSpec) {
        saved.removeAll { $0.id == spec.id }
        persist()
    }

    func clearHistory() {
        history.removeAll()
        persist()
    }

    // MARK: - cURL

    @discardableResult
    func importCurl(_ text: String) -> Bool {
        guard let spec = Curl.parse(text) else { return false }
        current = spec
        response = nil
        error = nil
        flash("Imported cURL")
        return true
    }

    func importCurlFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if !importCurl(text) { flash("Clipboard doesn't contain a cURL command") }
    }

    func copyCurl() {
        do {
            copy(Curl.export(try builtRequest()), label: "Copied as cURL")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func copy(_ text: String, label: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(label)
    }

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Persistence

    /// Last blob written to the Keychain — avoids rewriting it on every persist.
    @ObservationIgnored private var lastSecrets: SecretBlob?
    @ObservationIgnored private var keychainFailed = false
    /// The Keychain couldn't be read this session: never write it (that would replace real secrets with blanks).
    @ObservationIgnored private var keychainReadFailed = false
    /// The Keychain is read in the background after launch; until then it's never written.
    @ObservationIgnored private var keychainPending = false
    /// The state file exists but couldn't be read: don't overwrite it this session.
    @ObservationIgnored private var persistenceDisabled = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Edits to the current request and environments are saved shortly after they stop (crash safety).
    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { persist() }
        }
    }

    func persist() {
        guard !persistenceDisabled else { return }
        saveTask?.cancel()
        // Secret env values and OAuth tokens go to the Keychain; state.json gets blanks.
        var blob = SecretBlob(tokens: tokens)
        var envsOnDisk = envs
        for e in envsOnDisk.indices {
            for v in envsOnDisk[e].vars.indices where envsOnDisk[e].vars[v].secret {
                blob.values[envsOnDisk[e].vars[v].id.uuidString] = envsOnDisk[e].vars[v].value
                envsOnDisk[e].vars[v].value = ""
            }
        }
        var tokensOnDisk: [String: OAuthToken] = [:]
        if keychainReadFailed || keychainPending {
            // Keep this session's secrets in app data; they move into the Keychain once it can be read again.
            envsOnDisk = envs
            tokensOnDisk = tokens
        } else if lastSecrets == nil && blob.values.isEmpty && blob.tokens.isEmpty {
            // No secrets yet: don't create a Keychain item (or wake up the Security stack) for nothing.
        } else if blob != lastSecrets {
            if Secrets.save(blob) {
                lastSecrets = blob
            } else {
                // Never lose secrets: fall back to app data and say so once.
                envsOnDisk = envs
                tokensOnDisk = tokens
                if !keychainFailed { keychainFailed = true; flash("Keychain unavailable — secrets kept in app data") }
            }
        }
        let state = Persisted(saved: saved, history: history, envs: envsOnDisk, activeEnvID: activeEnvID, current: current, tokens: tokensOnDisk)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        defer { loaded = true }
        guard FileManager.default.fileExists(atPath: Self.fileURL.path) else { return }   // first launch
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            persistenceDisabled = true
            Task { @MainActor in self.flash("Couldn't read saved data — changes won't be saved this session") }
            return
        }
        guard let state = try? JSONDecoder().decode(Persisted.self, from: data) else {
            // Never silently overwrite data we couldn't read (corrupt file, or written by a newer version).
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = Self.fileURL.deletingLastPathComponent().appendingPathComponent("state.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: Self.fileURL, to: backup)
            Task { @MainActor in self.flash("Couldn't read saved data — kept a backup: \(backup.lastPathComponent)") }
            return
        }
        saved = state.saved
        history = state.history
        envs = state.envs.isEmpty ? [EnvSet()] : state.envs
        activeEnvID = state.activeEnvID
        if let c = state.current { current = c }
        tokens = state.tokens ?? [:]
        // Reading the Keychain can block (e.g. an access prompt after an update) — never on the launch path.
        keychainPending = true
        Task.detached(priority: .userInitiated) {
            let result = Secrets.read()
            await MainActor.run { self.applySecrets(result) }
        }
    }

    private func applySecrets(_ result: Secrets.ReadResult) {
        keychainPending = false
        switch result {
        case .found(let blob):
            lastSecrets = blob
            // Values in app data are newer (kept there while the Keychain was unavailable) — they win.
            tokens.merge(blob.tokens) { disk, _ in disk }
            for e in envs.indices {
                for v in envs[e].vars.indices where envs[e].vars[v].secret && envs[e].vars[v].value.isEmpty {
                    if let value = blob.values[envs[e].vars[v].id.uuidString] { envs[e].vars[v].value = value }
                }
            }
        case .notFound:
            break
        case .failed:
            keychainReadFailed = true
            Task { @MainActor in self.flash("Couldn't read the Keychain — saved secrets aren't loaded (and won't be overwritten)") }
        }
    }
}
