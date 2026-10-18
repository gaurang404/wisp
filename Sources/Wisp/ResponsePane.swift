import SwiftUI
import UniformTypeIdentifiers

struct ResponsePane: View {
    enum Tab: String, CaseIterable { case body = "Body", headers = "Headers" }

    @Environment(Store.self) private var store
    @State private var tab: Tab = .body
    @State private var raw = false
    @State private var filter = ""
    @State private var captureName = ""
    @State private var showCapture = false

    @State private var showFilter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                if let err = store.error {
                    errorState(err)
                } else if let r = store.response {
                    VStack(alignment: .leading, spacing: 0) {
                        detailsLine(r)
                        switch tab {
                        case .body: bodyView(r)
                        case .headers: CodeTextView(text: .constant(r.headerText), editable: false)
                        }
                    }
                } else if store.isSending {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(store.status ?? "Sending…").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .wispDemoFilter)) {
            filter = $0.object as? String ?? ""
            showFilter = true
        }
        #endif
    }

    /// Tabs on the left; status · time · size and a few quiet actions on the right.
    private var header: some View {
        HStack(spacing: 10) {
            TabBar(items: Tab.allCases, selection: $tab, title: \.rawValue,
                   badge: { t in t == .headers ? store.response.map { "\($0.headers.count)" } : nil })
            Spacer(minLength: 8)
            if store.isSending, store.response != nil { ProgressView().controlSize(.mini) }
            if let r = store.response, store.error == nil {
                summary(r)
                HStack(spacing: 2) {
                    if r.prettyJSON != nil, tab == .body {
                        IconButton(systemImage: showFilter || !filter.isEmpty ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                                   help: "Filter JSON") { showFilter.toggle(); if !showFilter { filter = "" } }
                        IconButton(systemImage: raw ? "curlybraces.square.fill" : "curlybraces.square",
                                   help: raw ? "Show pretty" : "Show raw") { raw.toggle() }
                    }
                    IconButton(systemImage: "doc.on.doc", help: "Copy body") { store.copy(displayed(r)) }
                    Menu {
                        Button("Copy Headers") { store.copy(r.headerText) }
                        Button("Save Body to File…") { saveToFile(r) }
                        Divider()
                        Toggle("Follow Redirects", isOn: Binding(get: { store.followRedirects }, set: { store.followRedirects = $0 }))
                        if r.body.count < 512_000, let jwt = JWT.find(in: r.text) {
                            Divider()
                            Button("Inspect JWT in Response") { store.sheet = .jwt(jwt) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// "200 OK · 312 ms · 2.1 KB" — colour only on the status.
    private func summary(_ r: ResponseData) -> some View {
        let status = Text("\(r.status) \(reasonPhrase(r.status))").fontWeight(.semibold).foregroundStyle(statusColor(r.status))
        let time = Text(formatDuration(r.duration))
        let size = Text(ByteCountFormatter.string(fromByteCount: Int64(r.body.count), countStyle: .file))
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { status; dot; time; dot; size }
            HStack(spacing: 6) { status; dot; time }
            status
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var dot: some View { Text("·").foregroundStyle(.tertiary) }

    /// Optional quiet line: provider insights, page number, Next page, filter.
    @ViewBuilder private func detailsLine(_ r: ResponseData) -> some View {
        let insights = Insights.from(status: r.status, headers: r.headers, body: r.body)
        let paging = store.hasNextPage || store.page > 1
        let notFollowed = (300..<400).contains(r.status) ? r.location : nil
        if !insights.isEmpty || paging || !r.redirects.isEmpty || notFollowed != nil {
            HStack(spacing: 12) {
                if let first = r.redirects.first {
                    Label("\(first.status) from \(first.from.host ?? first.from.absoluteString)", systemImage: "arrow.uturn.right")
                        .foregroundStyle(.secondary)
                        .help("Redirects followed:\n" + r.redirects.map { "\($0.status)  \($0.from.absoluteString)\n   → \($0.to.absoluteString)" }.joined(separator: "\n"))
                }
                if let location = notFollowed {
                    Label("Redirects to \(URL(string: location)?.host ?? location)", systemImage: "arrow.uturn.right")
                        .foregroundStyle(.secondary)
                        .help(location)
                    Button("Follow") {
                        store.followRedirects = true
                        store.send()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
                InsightLine(insights: insights)
                Spacer(minLength: 0)
                if store.page > 1 { Text("Page \(store.page)").foregroundStyle(.tertiary) }
                if store.hasNextPage {
                    Button { store.loadNextPage() } label: {
                        HStack(spacing: 3) { Text("Next page"); Image(systemName: "arrow.right") }
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Fetch the next page using this API's pagination")
                }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        if let raw = AuthHint.from(status: r.status, headers: r.headers, requestAuth: store.effective(store.current).auth.kind) {
            let hint = sensibleHint(raw)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hint.title).font(.system(size: 12.5, weight: .semibold))
                    Text(hint.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(carriesCredentials ? "Check credentials" : "Add \(hint.kind.rawValue) auth") {
                        if !carriesCredentials { store.current.auth.kind = hint.kind }
                        store.focusRequestTab = credentialsInHeaders ? "Headers" : "Auth"
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .font(.system(size: 12))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color.orange.opacity(0.08)))
            .padding(.horizontal, 12).padding(.top, 10)
        }
        if tab == .body, r.prettyJSON != nil, showFilter || !filter.isEmpty {
            filterBar(r).padding(.horizontal, 12).padding(.top, 10)
        }
        if r.prettyJSON != nil, GraphQL.looksLikeGraphQLResponse(r.body) {
            let errors = GraphQL.errors(in: r.body)
            if !errors.isEmpty { GraphQLErrorsBanner(messages: errors).padding(.horizontal, 12).padding(.top, 10) }
        }
    }

    /// The request already sends credentials (auth, an env-supplied auth, or a credential header).
    private var carriesCredentials: Bool {
        let eff = store.effective(store.current)
        return eff.auth.kind != .none || credentialsInHeaders
    }

    private var credentialsInHeaders: Bool {
        store.effective(store.current).headers.contains { $0.enabled && !$0.value.isEmpty && DocsExport.isSecret($0.key) }
    }

    /// Servers often advertise a scheme they don't actually want (Shopify says Basic but takes an access-token header):
    /// when credentials of another kind were sent, say they were rejected rather than suggesting a different auth type.
    private func sensibleHint(_ h: AuthHint) -> AuthHint {
        let sent = store.effective(store.current).auth.kind
        guard carriesCredentials, sent == .none || sent != h.kind else { return h }
        return AuthHint(kind: sent == .none ? .apiKey : sent,
                        title: "The credentials were rejected",
                        detail: "The server answered 401. Check that the token or key is valid, not expired, and has access to this resource.")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if Bundle.main.bundleURL.pathExtension == "app" {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .opacity(0.85)
            } else {
                Image(systemName: "paperplane")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            Text("Send a request to see the response")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                hint("⌘↩", "send")
                hint("⌘O", "import")
                hint("⇧⌘G", "GraphQL")
            }
            Button("Import an API from its docs") { store.sheet = .importer }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .font(.system(size: 12))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).foregroundStyle(.secondary)
            Text(label).foregroundStyle(.tertiary)
        }
        .font(.system(size: 11.5))
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.red.opacity(0.75))
            Text("Request failed").font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 340)
            Button("Try again") { store.send() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func bodyView(_ r: ResponseData) -> some View {
        if r.isHTML {
            HTMLResponseView(response: r)
        } else if r.isImage, let img = NSImage(data: r.body) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CodeTextView(text: .constant(displayed(r)), editable: false, highlightJSON: r.prettyJSON != nil && !raw)
                .padding(.horizontal, 6)
                .padding(.top, 4)
        }
    }

    private func filterBar(_ r: ResponseData) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("data.items[0].name  ·  items.id  ·  items.#", text: $filter)
                .textFieldStyle(.plain)
                .font(Theme.mono)
                .help("JSON filter: data.items[0].name · items.id (maps arrays) · items.# (count) · [-1] (last)")
            if !filter.trimmingCharacters(in: .whitespaces).isEmpty {
                if captureValue(r) == nil {
                    Text("no match").font(.caption).foregroundStyle(.orange)
                } else {
                    Button("Save as {{var}}") {
                        captureName = suggestedName
                        showCapture = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .font(.system(size: 11.5))
                    .help("Save this value as an environment variable — chain it into other requests")
                    .popover(isPresented: $showCapture, arrowEdge: .bottom) { capturePopover(r) }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .surface()
    }

    private var suggestedName: String {
        let parts = filter.replacingOccurrences(of: "]", with: "").split(whereSeparator: { $0 == "." || $0 == "[" })
        return parts.last { Int($0) == nil && $0 != "#" && $0 != "$" }.map(String.init) ?? "value"
    }

    /// Filter result as a plain variable value (JSON strings unquoted); nil when nothing matches.
    private func captureValue(_ r: ResponseData) -> String? {
        guard let out = JSONFormat.query(r.body, path: filter) else { return nil }
        if out.hasPrefix("\""), let d = out.data(using: .utf8),
           let s = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) as? String {
            return s
        }
        return out
    }

    private func capturePopover(_ r: ResponseData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save as variable").font(.headline)
            HStack(spacing: 2) {
                Text("{{").foregroundStyle(.secondary)
                TextField("name", text: $captureName).textFieldStyle(.soft).frame(width: 160)
                Text("}}").foregroundStyle(.secondary)
            }
            .font(.system(.body, design: .monospaced))
            Text((captureValue(r) ?? "").prefix(120))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Spacer()
                Button("Save") {
                    if let v = captureValue(r) { store.setVariable(captureName, v) }
                    showCapture = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(captureName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func displayed(_ r: ResponseData) -> String {
        guard let pretty = r.prettyJSON else { return r.text }
        if raw { return r.text }
        let f = filter.trimmingCharacters(in: .whitespaces)
        if f.isEmpty || f == "$" { return pretty }
        return JSONFormat.query(r.body, path: f) ?? "// no match for \(f)"
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        t < 1 ? "\(Int(t * 1000)) ms" : String(format: "%.2f s", t)
    }

    private func saveToFile(_ r: ResponseData) {
        let panel = NSSavePanel()
        let ext = r.prettyJSON != nil ? "json" : (r.url?.pathExtension.isEmpty == false ? r.url!.pathExtension : "txt")
        panel.nameFieldStringValue = "response.\(ext)"
        if panel.runModal() == .OK, let url = panel.url {
            let data = r.prettyJSON.map { Data($0.utf8) } ?? r.body
            try? data.write(to: url)
        }
    }
}
