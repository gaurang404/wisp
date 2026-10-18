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
                        Text("Reference variables as {{name}} in the URL, params, headers, body or auth. 🔒 = stored in the Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                        KeyValueEditor(items: binding(id).vars, keyPlaceholder: "name", valuePlaceholder: "value", allowSecrets: true)
                        let env = binding(id).wrappedValue
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
        .frame(width: 640, height: 420)
        .onAppear { selected = store.activeEnvID ?? store.envs.first?.id }
    }

    private func add() {
        let env = EnvSet(name: "Environment \(store.envs.count + 1)")
        store.envs.append(env)
        selected = env.id
    }

    private func remove() {
        guard let id = selected, store.envs.count > 1 else { return }
        store.envs.removeAll { $0.id == id }
        if store.activeEnvID == id { store.activeEnvID = nil }
        selected = store.envs.first?.id
    }

    private func binding(_ id: UUID) -> Binding<EnvSet> {
        Binding(
            get: { store.envs.first { $0.id == id } ?? EnvSet(id: id) },
            set: { v in if let i = store.envs.firstIndex(where: { $0.id == id }) { store.envs[i] = v } }
        )
    }
}
