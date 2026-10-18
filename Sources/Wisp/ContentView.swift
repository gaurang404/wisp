import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            VStack(spacing: 0) {
                URLBar()
                HSplitView {
                    RequestPane().frame(minWidth: 360, idealWidth: 460, maxHeight: .infinity)
                    ResponsePane().frame(minWidth: 340, idealWidth: 560, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("No Environment") { store.activeEnvID = nil }
                    Divider()
                    ForEach(store.envs) { env in
                        Button(env.name) { store.activeEnvID = env.id }
                    }
                    Divider()
                    Button("Manage Environments…") { store.sheet = .environments }
                } label: {
                    let name = store.envs.first { $0.id == store.activeEnvID }?.name
                    HStack(spacing: 6) {
                        Circle().fill(name == nil ? Color.secondary.opacity(0.4) : .green).frame(width: 7, height: 7)
                        Text(name ?? "No Environment").lineLimit(1)
                    }
                }
                .fixedSize()
                .help("Active environment — use {{name}} anywhere in a request")
                Button { store.sheet = .code } label: { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                    .help("Generate code — cURL, fetch, Python, Laravel, Go… (⌥⌘C)")
                Menu {
                    Button("New Request") { store.newRequest() }
                    Button("Import…") { store.sheet = .importer }
                    Divider()
                    Button("Import API from Docs or Spec URL…") { store.sheet = .importer }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("New request, import, or start from an API template")
            }
        }
        .onChange(of: store.activeEnvID) { store.persist() }
        .sheet(item: $store.sheet) { sheet in
            Group {
            switch sheet {
            case .code: CodeSheet()
            case .importer: ImportSheet()
            case .environments: EnvEditor()
            case .jwt(let token): JWTSheet(token: token)
            case .graphQLBuilder: GraphQLBuilderSheet()
            }
            }
            .tint(Theme.accent)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    Task { @MainActor in store.importData(data) }
                }
            }
            return !providers.isEmpty
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast)
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.thickMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        #if DEBUG
        .debugSnapshotHook(store)
        #endif
    }
}

struct URLBar: View {
    @Environment(Store.self) private var store
    @FocusState private var urlFocused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if !store.current.folder.isEmpty {
                    Text(store.current.folder.replacingOccurrences(of: "/", with: " › ") + " ›")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(-1)
                }
                TextField("Untitled request", text: $store.current.name)
                    .textFieldStyle(.plain)
                    .fontWeight(.semibold)
                if store.current.auth.kind == .none, let env = store.activeEnv, env.auth.kind != .none,
                   store.applies(env, to: store.current) {
                    Label("Auth from \(env.name)", systemImage: "key.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .help("This request has no auth of its own, so it uses \(env.name)'s \(env.auth.kind.rawValue) auth.")
                }
                Button { store.save() } label: {
                    Image(systemName: store.isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 12))
                        .foregroundStyle(store.isSaved ? Theme.accent : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(store.isSaved ? "Saved — ⌘S to update" : "Save (⌘S)")
            }
            .font(.system(size: 14))

            HStack(spacing: 0) {
                Menu {
                    ForEach(HTTPMethod.allCases) { m in
                        Button(m.rawValue) { store.current.method = m }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.current.method.rawValue)
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(store.current.method.color)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    }
                    .frame(width: 78, height: 34)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                Rectangle().fill(Theme.stroke).frame(width: 1, height: 18)

                TextField("https://api.example.com/users  —  or paste a cURL", text: $store.current.url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($urlFocused)
                    .padding(.horizontal, 10)
                    .onSubmit { store.send() }
                    .onChange(of: store.current.url) { _, new in
                        if new.trimmingCharacters(in: .whitespaces).hasPrefix("curl ") { store.importCurl(new) }
                    store.urlChanged()
                    }

                SendButton(sending: store.isSending) {
                    store.isSending ? store.cancel() : store.send()
                }
                .padding(3)
            }
            .frame(height: 36)
            .surface(focused: urlFocused)

            if store.canMakeReusable {
                ReuseHint().transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }
}

private struct SendButton: View {
    let sending: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if sending {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: "paperplane.fill").font(.system(size: 10.5))
                }
                Text(sending ? "Cancel" : "Send")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(sending ? Color.gray : Theme.accent)
                    .brightness(hover ? 0.06 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(sending ? "Cancel (⌘.)" : "Send (⌘↩)")
    }
}

/// Shown when the request carries literal credentials (e.g. a pasted cURL with a token).
private struct ReuseHint: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
            Text("This request contains credentials.").foregroundStyle(.secondary)
            Button("Save to Keychain & reuse for \(store.currentHost ?? "this API")") { store.makeReusable() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help("Moves the secrets into Keychain-backed variables, sets {{baseUrl}}, and lets every request to this host use the same auth.")
            Spacer()
            Button { store.dismissedHints.insert(store.current.url) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Not now")
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 4)
    }
}
