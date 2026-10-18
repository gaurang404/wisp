import SwiftUI

struct SidebarView: View {
    @Environment(Store.self) private var store
    @State private var search = ""
    @State private var openedHistoryID: UUID?

    private func matches(_ r: RequestSpec) -> Bool {
        search.isEmpty
            || r.displayName.localizedCaseInsensitiveContains(search)
            || r.url.localizedCaseInsensitiveContains(search)
    }

    @State private var collapsed: Set<String> = []

    private func folders(_ items: [RequestSpec]) -> [String] {
        var seen = Set<String>()
        return items.map(\.folder).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Every folder path including intermediate ones ("A/B" → "A", "A/B"), in first-appearance order.
    private func allFolders(_ items: [RequestSpec]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for f in items.map(\.folder) where !f.isEmpty {
            let parts = f.split(separator: "/", omittingEmptySubsequences: false)
            for n in 1...parts.count {
                let path = parts.prefix(n).joined(separator: "/")
                if seen.insert(path).inserted { out.append(path) }
            }
        }
        return out
    }

    private func children(of parent: String, in tree: [String]) -> [String] {
        tree.filter { path in
            guard let slash = path.lastIndex(of: "/") else { return parent.isEmpty }
            return String(path[..<slash]) == parent
        }
    }

    private func folderNode(_ path: String, items: [RequestSpec], tree: [String]) -> AnyView {
        AnyView(
            DisclosureGroup(isExpanded: expanded(path)) {
                ForEach(children(of: path, in: tree), id: \.self) { folderNode($0, items: items, tree: tree) }
                ForEach(items.filter { $0.folder == path }) { savedRow($0) }
            } label: {
                Label(String(path.split(separator: "/").last ?? Substring(path)), systemImage: "folder")
                    .lineLimit(1)
                    .help(path)
                    .contextMenu {
                        Button("Export Docs…") { store.exportDocs(folder: path) }
                        Divider()
                        Button("Delete Folder", role: .destructive) { store.deleteFolder(path) }
                    }
            }
        )
    }

    private func expanded(_ folder: String) -> Binding<Bool> {
        Binding(
            get: { !search.isEmpty || !collapsed.contains(folder) },
            set: { if $0 { collapsed.remove(folder) } else { collapsed.insert(folder) } }
        )
    }

    private func pathOf(_ url: String) -> String {
        guard let c = URLComponents(string: url), c.host != nil else { return url }
        let p = c.percentEncodedPath + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
        return p.isEmpty ? "/" : p
    }

    private func hostOf(_ url: String) -> String {
        URLComponents(string: url)?.host.map { "· " + $0 } ?? ""
    }

    private func savedRow(_ r: RequestSpec) -> some View {
        HStack(spacing: 6) {
            MethodLabel(method: r.method)
            Text(r.displayName).lineLimit(1)
        }
        .padding(.vertical, 1)
        .help(r.url)
        .modifier(RowTap(active: r.id == store.current.id && openedHistoryID == nil) {
            openedHistoryID = nil
            store.open(r)
        })
        .contextMenu {
            Button("Duplicate") { store.duplicate(r) }
            Menu("Move to") {
                Button("No Folder") { store.moveToFolder(r, "") }
                Divider()
                ForEach(folders(store.saved), id: \.self) { f in Button(f) { store.moveToFolder(r, f) } }
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(r) }
        }
    }

    var body: some View {
        List {
            Section("Saved") {
                let items = store.saved.filter(matches)
                if items.isEmpty {
                    Text(search.isEmpty ? "⌘S to save a request" : "No matches")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(items.filter { $0.folder.isEmpty }) { savedRow($0) }
                let tree = allFolders(items)
                ForEach(children(of: "", in: tree), id: \.self) { folderNode($0, items: items, tree: tree) }
            }

            Section {
                ForEach(store.history.filter { matches($0.request) }.prefix(100)) { h in
                    HStack(spacing: 6) {
                        MethodLabel(method: h.request.method)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pathOf(h.request.url)).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 5) {
                                Circle().fill(statusColor(h.status)).frame(width: 6, height: 6)
                                Text(h.status.map(String.init) ?? "ERR")
                                Text("·")
                                Text(shortAgo(h.date))
                                Text(hostOf(h.request.url)).lineLimit(1).truncationMode(.tail)
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 1)
                    .modifier(RowTap(active: h.id == openedHistoryID) {
                        openedHistoryID = h.id
                        store.open(h.request)
                    })
                }
            } header: {
                HStack {
                    Text("History")
                    Spacer()
                    if !store.history.isEmpty {
                        Button("Clear") { store.clearHistory() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Filter")
        .onChange(of: store.current.id) { _, id in
            // Request replaced from elsewhere (⌘N, cURL import, save-as) → drop the history highlight.
            if let hid = openedHistoryID, store.history.first(where: { $0.id == hid })?.request.id != id {
                openedHistoryID = nil
            }
        }
    }
}

/// Click-to-open row with a manual highlight (avoids List selection side effects).
private struct RowTap: ViewModifier {
    let active: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .listRowBackground(
                active ? RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.25)).padding(.horizontal, 8) : nil
            )
    }
}
