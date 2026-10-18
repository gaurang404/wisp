import SwiftUI

struct RequestPane: View {
    enum Tab: String, CaseIterable { case params = "Params", headers = "Headers", body = "Body", auth = "Auth", docs = "Docs" }

    @Environment(Store.self) private var store
    @State private var tab: Tab = .params

    private func badge(_ t: Tab) -> String? {
        let c = store.current
        switch t {
        case .params:
            let n = c.params.filter { $0.enabled && !$0.key.isEmpty }.count
            return n > 0 ? "\(n)" : nil
        case .headers:
            let n = c.headers.filter { $0.enabled && !$0.key.isEmpty }.count
            return n > 0 ? "\(n)" : nil
        case .body: return c.bodyKind == .none ? nil : ""
        case .auth: return c.auth.kind == .none ? nil : ""
        case .docs: return c.docs.isEmpty ? nil : ""
        }
    }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            TabBar(items: Tab.allCases, selection: $tab, title: \.rawValue, badge: badge)
                .padding(.horizontal, 16)
            Divider()
            Group {
            switch tab {
            case .params:
                KeyValueEditor(items: $store.current.params, keyPlaceholder: "param", valuePlaceholder: "value")
            case .headers:
                VStack(alignment: .leading, spacing: 8) {
                    KeyValueEditor(items: $store.current.headers, keyPlaceholder: "Header", valuePlaceholder: "value")
                        .fixedSize(horizontal: false, vertical: true)
                    let inherited = store.effective(store.current).headers.count - store.current.headers.filter { $0.enabled && !$0.key.isEmpty }.count
                    if inherited > 0, let env = store.activeEnv {
                        Text("+ \(inherited) header\(inherited == 1 ? "" : "s") from \(env.name): \(env.headers.map(\.key).joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            case .body:
                BodyEditor()
            case .auth:
                AuthEditor()
            case .docs:
                DocsEditor()
            }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: store.current.id) {
            tab = store.current.bodyKind == .none ? .params : .body
        }
        .onChange(of: store.focusRequestTab) { _, requested in
            if let requested, let t = Tab(rawValue: requested) { tab = t }
            store.focusRequestTab = nil
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .wispDemoTab)) { n in
            if let t = Tab(rawValue: n.object as? String ?? "") { tab = t }
        }
        #endif
    }
}

private struct BodyEditor: View {
    @Environment(Store.self) private var store
    @State private var invalid = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ChoiceChips(items: BodyKind.allCases, selection: $store.current.bodyKind, title: \.rawValue)
                Spacer()
                if store.current.bodyKind == .json {
                    if invalid { Text("Invalid JSON").font(.caption).foregroundStyle(.red) }
                    Button {
                        if let p = JSONFormat.pretty(store.current.body) { store.current.body = p; invalid = false }
                        else { invalid = true }
                    } label: { Label("Beautify", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
            switch store.current.bodyKind {
            case .none:
                VStack(spacing: 6) {
                    Image(systemName: "doc").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text("No body").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .json, .text:
                CodeTextView(text: $store.current.body, highlightJSON: store.current.bodyKind == .json)
                    .padding(.horizontal, -8)
                    .onChange(of: store.current.body) { invalid = false }
            case .graphql:
                GraphQLEditor()
                    // Read the schema shortly after the endpoint settles, so the builder opens instantly.
                    .task(id: store.endpointKey) {
                        try? await Task.sleep(for: .milliseconds(800))
                        if !Task.isCancelled, store.currentSchema == nil, !store.schemaLoading { await store.loadSchema(auto: true) }
                    }
            case .form:
                KeyValueEditor(items: $store.current.form, keyPlaceholder: "field", valuePlaceholder: "value")
            }
        }
        .onChange(of: store.current.bodyKind) { _, kind in
            if kind == .graphql, store.current.method == .GET { store.current.method = .POST }
        }
    }
}

private struct AuthEditor: View {
    @Environment(Store.self) private var store

    private func authSummary(_ a: Auth) -> String {
        switch a.kind {
        case .bearer: "Authorization: Bearer \(a.token)"
        case .basic: "Basic \(a.username) : ••••"
        case .apiKey: a.apiKeyIn == .header ? "\(a.apiKeyName): \(a.apiKeyValue)" : "?\(a.apiKeyName)=\(a.apiKeyValue)"
        case .oauth2: "OAuth 2 · \(a.oauth.grant.rawValue)"
        case .none: ""
        }
    }

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ChoiceChips(items: AuthKind.allCases, selection: $store.current.auth.kind, title: \.rawValue)
                    .padding(.bottom, 4)

                Group {
                    switch store.current.auth.kind {
                    case .none:
                        if let env = store.activeEnv, env.auth.kind != .none, store.applies(env, to: store.current) {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Using \(env.name)'s \(env.auth.kind.rawValue) auth", systemImage: "key.fill")
                                    .font(.callout.weight(.medium))
                                Text(authSummary(env.auth)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                Button("Override for this request") { store.current.auth = env.auth }
                                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
                            }
                        } else {
                            Text("No auth. Pick a type above — or paste a cURL that has a token and Wisp offers to save it to the Keychain for the whole API.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    case .bearer:
                        TextField("Token or {{token}}", text: $store.current.auth.token)
                        if JWT.decode(Resolver(vars: store.activeVars)(store.current.auth.token)) != nil {
                            Button("Inspect JWT") { store.sheet = .jwt(Resolver(vars: store.activeVars)(store.current.auth.token)) }
                        }
                    case .basic:
                        TextField("Username", text: $store.current.auth.username)
                        SecureField("Password", text: $store.current.auth.password)
                    case .apiKey:
                        HStack {
                            Text("Add to").foregroundStyle(.secondary)
                            ChoiceChips(items: APIKeyLocation.allCases, selection: $store.current.auth.apiKeyIn, title: \.rawValue)
                        }
                        .font(.body)
                        TextField(store.current.auth.apiKeyIn == .header ? "Header name, e.g. X-API-Key" : "Query param, e.g. api_key",
                                  text: $store.current.auth.apiKeyName)
                        TextField("Key or {{apiKey}}", text: $store.current.auth.apiKeyValue)
                    case .oauth2:
                        OAuthEditor()
                    }
                }
                .textFieldStyle(.soft)
                .font(.system(.body, design: .monospaced))

                if store.current.auth.kind != .none, let env = store.activeEnv {
                    Button("Use this auth for every request to \(env.name)") { store.shareAuthWithEnvironment() }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
                        .padding(.top, 6)
                        .help("Moves this auth to the environment; requests without their own auth will use it.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OAuthEditor: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        let grant = store.current.auth.oauth.grant
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Grant").font(.callout).foregroundStyle(.secondary).frame(width: 96, alignment: .trailing)
                SoftMenu(items: OAuthGrant.allCases, selection: $store.current.auth.oauth.grant, title: \.rawValue)
                    .font(.body)
            }
            if grant == .authorizationCode {
                field("Authorize URL", $store.current.auth.oauth.authURL, "https://example.com/oauth/authorize")
            }
            field("Token URL", $store.current.auth.oauth.tokenURL, "https://example.com/oauth/token")
            field("Client ID", $store.current.auth.oauth.clientID, "{{clientId}}")
            field("Client Secret", $store.current.auth.oauth.clientSecret, "optional with PKCE")
            field("Scope", $store.current.auth.oauth.scope, "read write")
            if grant == .authorizationCode {
                field("Redirect URI", $store.current.auth.oauth.redirectURI, "http://127.0.0.1:53682/callback")
            }
            if grant == .password {
                field("Username", $store.current.auth.oauth.username, "")
                field("Password", $store.current.auth.oauth.password, "")
            }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    field("Audience", $store.current.auth.oauth.audience, "optional (Auth0 etc.)")
                    Toggle("Send client credentials in body (instead of Basic header)", isOn: $store.current.auth.oauth.clientAuthInBody)
                        .font(.callout)
                }
                .padding(.top, 6)
            }
            .font(.callout)

            Divider().padding(.vertical, 4)
            tokenStatus
            Text(grant == .authorizationCode
                 ? "Send just works: Wisp opens your browser to sign in (PKCE), catches the redirect locally, then caches and auto-refreshes the token for every request using this client."
                 : "Send just works: Wisp fetches the token, caches it for every request using this client, and renews it when it expires.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var tokenStatus: some View {
        HStack(spacing: 10) {
            if let t = store.currentToken {
                Image(systemName: t.isExpired ? "clock.badge.exclamationmark" : "checkmark.seal.fill")
                    .foregroundStyle(t.isExpired ? .orange : .green)
                if let exp = t.expiresAt {
                    Text(t.isExpired ? "Token expired" : "Token valid · expires \(exp, style: .relative)")
                } else {
                    Text("Token cached")
                }
                if t.refreshToken != nil { Text("· refreshable").foregroundStyle(.secondary) }
            } else {
                Image(systemName: "key").foregroundStyle(.secondary)
                Text("No token yet").foregroundStyle(.secondary)
            }
            Spacer()
            if let t = store.currentToken {
                Button("Copy") { store.copy(t.accessToken, label: "Copied access token") }
                if JWT.decode(t.accessToken) != nil { Button("Inspect") { store.sheet = .jwt(t.accessToken) } }
                Button("Clear") { store.clearToken() }
            }
            Button("Get New Token") { store.getNewToken() }.disabled(store.isSending)
        }
        .font(.callout)
        .buttonStyle(.borderless)
    }

    private func field(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 96, alignment: .trailing)
            TextField(placeholder, text: text)
        }
    }
}

private struct DocsEditor: View {
    @Environment(Store.self) private var store
    @State private var editing = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                TextField("Folder (e.g. Billing/Invoices)", text: $store.current.folder)
                    .textFieldStyle(.soft)
                Toggle("Edit", isOn: $editing).toggleStyle(.button)
            }
            if editing || store.current.docs.isEmpty {
                CodeTextView(text: $store.current.docs)
                    .padding(.horizontal, -8)
                    .overlay(alignment: .topLeading) {
                        if store.current.docs.isEmpty {
                            Text("Markdown notes for this request — purpose, gotchas, example values…")
                                .foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
                        }
                    }
            } else {
                MarkdownView(text: store.current.docs)
            }
        }
    }
}
