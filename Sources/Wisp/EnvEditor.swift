import SwiftUI

struct EnvEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $selected) {
                        ForEach(store.envs) { env in
                            HStack {
                                Text(env.name)
                                if env.id == store.activeEnvID {
                                    Spacer()
                                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                                }
                            }
                            .tag(env.id)
                        }
                    }
                    HStack(spacing: 2) {
                        Button { add() } label: { Image(systemName: "plus") }
                        Button { remove() } label: { Image(systemName: "minus") }
                            .disabled(selected == nil || store.envs.count <= 1)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(minWidth: 150, maxWidth: 200)

                VStack(alignment: .leading, spacing: 10) {
                    if let id = selected, store.envs.contains(where: { $0.id == id }) {
                        TextField("Name", text: binding(id).name)
                            .textFieldStyle(.soft)
                            .font(.headline)
                        Text("Reference variables as {{name}} in the URL, params, headers, body or auth. 🔒 = stored in the Keychain"
                             + (binding(id).wrappedValue.keys.isEmpty ? "." : ", values from the key selected below."))
                            .font(.caption).foregroundStyle(.secondary)
                        KeyValueEditor(items: vars(id), keyPlaceholder: "name", valuePlaceholder: "value", allowSecrets: true)
                        let env = binding(id).wrappedValue
                        KeysSection(envID: id)
                        HStack(spacing: 6) {
                            Text("Default auth").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .help(env.host.map { "Applied only to requests for \($0)." } ?? "Add a baseUrl variable to use default auth and headers — they're only sent to that API's host.")
                            if env.auth.kind == .none {
                                Text("none — set one from a request's Auth tab").font(.caption).foregroundStyle(.tertiary)
                            } else {
                                Text(env.auth.kind.rawValue).font(.caption)
                                Button("Remove") { binding(id).wrappedValue.auth = Auth() }
                                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.caption)
                            }
                        }
                        Text("Default headers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        KeyValueEditor(items: binding(id).headers, keyPlaceholder: "Header", valuePlaceholder: "value")
                            .frame(maxHeight: 110)
                        Toggle("Use this environment", isOn: Binding(
                            get: { store.activeEnvID == id },
                            set: { store.activeEnvID = $0 ? id : nil }
                        ))
                    } else {
                        Text("Select an environment").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(12)
                .frame(minWidth: 380)
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
        .frame(width: 660, height: 560)
        .onAppear { selected = store.activeEnvID ?? store.envs.first?.id }
    }

    private func add() {
        let env = EnvSet(name: "Environment \(store.envs.count + 1)")
        store.envs.append(env)
        selected = env.id
    }

    private func remove() {
        guard let id = selected, store.envs.count > 1 else { return }
        store.deleteEnv(id)
        selected = store.envs.first?.id
    }

    /// Editing a 🔒 variable edits the key in use too.
    private func vars(_ id: UUID) -> Binding<[KeyValue]> {
        Binding(get: { binding(id).wrappedValue.vars }, set: { store.setVars($0, in: id) })
    }

    private func binding(_ id: UUID) -> Binding<EnvSet> {
        Binding(
            get: { store.envs.first { $0.id == id } ?? EnvSet(id: id) },
            set: { v in if let i = store.envs.firstIndex(where: { $0.id == id }) { store.envs[i] = v } }
        )
    }
}

/// Named values for the environment's 🔒 variables (e.g. "Main", "Test account"). Picking one fills the variables above.
private struct KeysSection: View {
    @Environment(Store.self) private var store
    let envID: UUID
    @State private var adding = false
    @State private var newName = ""
    @State private var newValues: [String: String] = [:]

    var body: some View {
        if let env = store.envs.first(where: { $0.id == envID }), !env.secretNames.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Keys").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if !adding {
                        Button("+ Add key") { startAdding(env) }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.caption)
                            .help("Keep another set of values for " + env.secretNames.map { "{{\($0)}}" }.joined(separator: ", "))
                    }
                }
                if env.keys.isEmpty && !adding {
                    Text("One key. Add another (e.g. a test account) to switch between them from the toolbar.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                let inUse = env.keyInUse?.id
                ForEach(env.keys) { key in
                    HStack(spacing: 8) {
                        Button { store.useKey(key.id, in: envID) } label: {
                            Image(systemName: inUse == key.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(inUse == key.id ? Theme.accent : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(inUse == key.id ? "In use" : "Use this key")
                        TextField("Name", text: name(key.id)).textFieldStyle(.plain)
                        Text(hint(key)).font(Theme.mono).foregroundStyle(.tertiary)
                        Button { store.deleteKey(key.id, in: envID) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Delete key — removes it from Wisp and the Keychain")
                    }
                    .font(.system(size: 12))
                }
                if env.hasUnsavedKey && !env.keys.isEmpty {
                    HStack(spacing: 6) {
                        Text("The values above aren't saved as a key.").font(.caption).foregroundStyle(.secondary)
                        Button("Save as \(env.nextKeyName)") { store.saveKey(named: env.nextKeyName) }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.caption)
                            .disabled(store.activeEnvID != envID)
                    }
                }
                if adding { addForm(env) }
            }
        }
    }

    private func addForm(_ env: EnvSet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Key name", text: $newName).textFieldStyle(.soft)
            ForEach(env.secretNames, id: \.self) { n in
                SecureField(n, text: Binding(get: { newValues[n, default: ""] }, set: { newValues[n] = $0 }))
                    .textFieldStyle(.soft)
            }
            HStack {
                Spacer()
                Button("Cancel") { adding = false }
                Button("Save & Use") { save(env) }
                    .buttonStyle(.borderedProminent)
                    .disabled(newValues.values.allSatisfy { $0.isEmpty })
            }
        }
        .padding(8)
        .surface()
    }

    private func startAdding(_ env: EnvSet) {
        newName = env.keys.isEmpty ? "Key 2" : env.nextKeyName
        newValues = [:]
        adding = true
    }

    private func save(_ env: EnvSet) {
        store.addKey(named: newName, credentials: newValues, in: envID)
        adding = false
    }

    private func name(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.envs.first { $0.id == envID }?.keys.first { $0.id == id }?.name ?? "" },
            set: { v in
                guard let e = store.envs.firstIndex(where: { $0.id == envID }),
                      let k = store.envs[e].keys.firstIndex(where: { $0.id == id }) else { return }
                store.envs[e].keys[k].name = v
            }
        )
    }

    /// "••••3f2a" — enough to tell keys apart without showing them.
    private func hint(_ key: SavedKey) -> String {
        guard let v = key.credentials.sorted(by: { $0.key < $1.key }).first?.value, v.count >= 12 else { return "••••" }
        return "••••" + v.suffix(4)
    }
}
