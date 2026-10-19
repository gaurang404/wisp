import SwiftUI

/// Named credentials for the active environment: add, rename, edit, use and delete them.
struct KeyManager: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let env = store.activeEnv {
                HSplitView {
                    VStack(spacing: 0) {
                        List(selection: $selected) {
                            ForEach(env.keys) { key in
                                HStack {
                                    Text(key.name)
                                    if env.keyInUse?.id == key.id {
                                        Spacer()
                                        Text("In use").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .tag(key.id)
                            }
                        }
                        HStack(spacing: 2) {
                            Button { add(env) } label: { Image(systemName: "plus") }
                                .help(env.hasUnsavedKey ? "Save the key in use" : "New key")
                            Button { remove(env) } label: { Image(systemName: "minus") }
                                .disabled(selected == nil)
                                .help("Delete key — removes it from Wisp and the Keychain")
                            Spacer()
                        }
                        .buttonStyle(.borderless)
                        .padding(6)
                    }
                    .frame(minWidth: 150, maxWidth: 200)

                    VStack(alignment: .leading, spacing: 10) {
                        if let id = selected, env.keys.contains(where: { $0.id == id }) {
                            TextField("Name", text: binding(env.id, id).name)
                                .textFieldStyle(.soft)
                                .font(.headline)
                            Text("Values for this environment's secret variables, e.g. {{apiKey}}. Stored in the Keychain.")
                                .font(.caption).foregroundStyle(.secondary)
                            KeyValueEditor(items: secretValues(env.id, id), keyPlaceholder: "variable", valuePlaceholder: "value")
                            HStack {
                                if store.activeEnv?.keyInUse?.id == id {
                                    Label("In use for \(env.name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                } else {
                                    Button("Use this key") { store.useKey(id) }
                                }
                                Spacer()
                                Button("Delete", role: .destructive) { remove(env) }
                            }
                        } else {
                            Text(env.keys.isEmpty
                                 ? "No saved keys for \(env.name). Press + to save the key in use, or paste a request with another key — Wisp keeps both."
                                 : "Select a key")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(12)
                    .frame(minWidth: 380)
                }
            } else {
                Text("Pick an environment first — keys belong to an API's environment.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { store.persist(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 640, height: 380)
        .onAppear { selected = store.activeEnv?.keyInUse?.id ?? store.activeEnv?.keys.first?.id }
    }

    /// Saves the unsaved key in use; otherwise starts a blank key with the same variable names.
    private func add(_ env: EnvSet) {
        guard let i = store.envs.firstIndex(where: { $0.id == env.id }) else { return }
        let names = Set(env.credentials.keys).union(env.keys.flatMap { $0.credentials.keys })
        var key = SavedKey(name: env.nextKeyName, credentials: env.hasUnsavedKey ? env.credentials : [:])
        if !env.hasUnsavedKey { key.values = names.sorted().map { KeyValue(key: $0, secret: true) } }
        store.envs[i].keys.append(key)
        selected = key.id
    }

    private func remove(_ env: EnvSet) {
        guard let id = selected else { return }
        store.deleteKey(id, in: env.id)
        selected = store.activeEnv?.keyInUse?.id ?? store.activeEnv?.keys.first?.id
    }

    private func binding(_ envID: UUID, _ id: UUID) -> Binding<SavedKey> {
        Binding(
            get: { store.envs.first { $0.id == envID }?.keys.first { $0.id == id } ?? SavedKey(id: id, name: "", credentials: [:]) },
            set: { v in
                guard let e = store.envs.firstIndex(where: { $0.id == envID }),
                      let k = store.envs[e].keys.firstIndex(where: { $0.id == id }) else { return }
                // Editing the key in use edits what's sent, too.
                let inUse = store.envs[e].keyInUse?.id == id
                store.envs[e].keys[k] = v
                if inUse { store.envs[e].use(v) }
            }
        )
    }

    /// Key values are always secret (masked, Keychain-stored).
    private func secretValues(_ envID: UUID, _ id: UUID) -> Binding<[KeyValue]> {
        let key = binding(envID, id)
        return Binding(
            get: { key.wrappedValue.values },
            set: { items in
                key.wrappedValue.values = items.map { var v = $0; if !v.key.isEmpty || !v.value.isEmpty { v.secret = true }; return v }
            }
        )
    }
}
