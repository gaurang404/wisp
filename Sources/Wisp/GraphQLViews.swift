import SwiftUI

// MARK: - Body editor

/// GraphQL body: query + variables, schema status, and a friendly start for people new to GraphQL.
struct GraphQLEditor: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SchemaStatus()
                Spacer(minLength: 0)
                Button { store.current.body = GraphQL.format(store.current.body) } label: {
                    Label("Prettify", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderless)
                .disabled(store.current.body.isEmpty)
                Button { store.sheet = .graphQLBuilder } label: {
                    Label("Build Query", systemImage: "square.grid.3x3.topleft.filled")
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Pick fields from the API's schema — no GraphQL knowledge needed")
            }
            .font(.callout)

            if store.current.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                GraphQLOnboarding()
            } else {
                CodeTextView(text: $store.current.body, highlightGraphQL: true)
                    .padding(.horizontal, -8)
                    .frame(minHeight: 140)
                Divider()
                HStack {
                    Text("Variables").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("JSON — values for the $names used in the query").font(.caption).foregroundStyle(.tertiary)
                }
                CodeTextView(text: $store.current.graphQLVariables, highlightJSON: true)
                    .padding(.horizontal, -8)
                    .frame(height: 110)
            }
        }
    }
}

private struct SchemaStatus: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            if store.schemaLoading {
                ProgressView().controlSize(.mini)
                Text("Reading schema…").foregroundStyle(.secondary)
            } else if let schema = store.currentSchema {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Schema ready")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(schema.rootFields(.query).count) queries · \(schema.rootFields(.mutation).count) mutations · \(schema.typeCount) types")
                IconButton(systemImage: "arrow.clockwise", help: "Reload schema") { Task { await store.loadSchema(force: true) } }
            } else if store.schemaError != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("No schema").foregroundStyle(.secondary)
                    .help(store.schemaError ?? "")
                Button("Retry") { Task { await store.loadSchema(force: true) } }.buttonStyle(.borderless)
            } else {
                Button { Task { await store.loadSchema() } } label: {
                    Label("Load Schema", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .disabled(store.current.url.isEmpty)
            }
        }
    }
}

private struct GraphQLOnboarding: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New to GraphQL? You don't need to write any.")
                .font(.headline)
            step(1, "Paste the API's GraphQL endpoint in the URL bar", detail: "Usually ends in /graphql. Add auth in the Auth tab if it needs it.")
            step(2, "Click Build Query", detail: "Wisp reads the API's schema and lists everything you can ask for.")
            step(3, "Tick the fields you want, fill in any inputs", detail: "Wisp writes the query and variables for you. Then hit Send.")
            HStack(spacing: 10) {
                Button { store.sheet = .graphQLBuilder } label: {
                    Label("Build Query", systemImage: "square.grid.3x3.topleft.filled")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.current.url.isEmpty)
                Button { store.tryGraphQLDemo() } label: {
                    Label("Try a demo API", systemImage: "globe.europe.africa")
                }
                Spacer()
            }
            .padding(.top, 4)
            HStack(spacing: 4) {
                Text("Know GraphQL already?").foregroundStyle(.tertiary)
                // Lets people who know GraphQL start typing immediately.
                Button("Write the query by hand") { store.current.body = "query {\n  \n}" }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
            .font(.caption)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface()
    }

    private func step(_ n: Int, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Query builder

struct GraphQLBuilderSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var op: GQLOperation = .query
    @State private var search = ""
    @State private var field: GQLField?
    @State private var selection: Set<String> = []
    @State private var args: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Query Builder").font(.headline)
                Text("Pick an operation, tick fields, fill inputs — Wisp writes the GraphQL.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            content
            Divider()
            HStack {
                if let field {
                    Text("\(op.keyword) \(field.name) · \(selection.count) field\(selection.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Query") { apply(send: false) }.disabled(field == nil)
                Button("Use & Send") { apply(send: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(field == nil)
            }
            .padding(12)
        }
        .frame(width: 1040, height: 640)
        .task {
            await store.loadSchema()
            #if DEBUG
            if let name = ProcessInfo.processInfo.environment["WISP_DEMO_GQL_FIELD"], let schema = store.currentSchema,
               let f = schema.rootFields(op).first(where: { $0.name == name }) {
                choose(f, schema)
                for pair in (ProcessInfo.processInfo.environment["WISP_DEMO_GQL_ARGS"] ?? "").split(separator: ",") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 { args[kv[0]] = kv[1] }
                }
            }
            #endif
        }
    }

    @ViewBuilder private var content: some View {
        if let schema = store.currentSchema {
            HStack(spacing: 0) {
                operationList(schema).frame(width: 280)
                Divider()
                if let field {
                    fieldDetail(field, schema).frame(maxWidth: .infinity)
                    Divider()
                    preview(field, schema).frame(width: 340)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.point.left").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                        Text("Choose what you want to \(op == .query ? "fetch" : "change") on the left").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if store.schemaLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading the API's schema…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30, weight: .light)).foregroundStyle(.orange)
                Text("Couldn't read the schema").font(.headline)
                Text(store.schemaError ?? "Enter the GraphQL endpoint URL first.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                    .textSelection(.enabled)
                Text("Check the URL and any auth the API needs (Auth / Headers tabs). Some production APIs disable schema introspection — you can still write queries by hand.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 460)
                Button("Try Again") { Task { await store.loadSchema(force: true) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Left: operations
    private func operationList(_ schema: GQLSchema) -> some View {
        let ops = GQLOperation.allCases.filter { !schema.rootFields($0).isEmpty }
        let fields = schema.rootFields(op).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || ($0.description ?? "").localizedCaseInsensitiveContains(search)
        }
        return VStack(alignment: .leading, spacing: 8) {
            if ops.count > 1 {
                ChoiceChips(items: ops, selection: $op, title: { $0 == .query ? "Read (Query)" : "Change (Mutation)" })
            }
            TextField("Search operations", text: $search).textFieldStyle(.soft)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(fields) { f in
                        let on = f == field
                        Button { choose(f, schema) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(f.name).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                    Text(f.type.display).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                if let d = f.description, !d.isEmpty {
                                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .onChange(of: op) { field = nil }
    }

    // Middle: inputs + field tree
    private func fieldDetail(_ f: GQLField, _ schema: GQLSchema) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.name).font(.system(size: 16, weight: .semibold, design: .monospaced))
                    if let d = f.description, !d.isEmpty { Text(d).font(.callout).foregroundStyle(.secondary) }
                }
                if !f.args.isEmpty {
                    section("Inputs", hint: "Fill what you need — starred ones are required")
                    ForEach(f.args) { arg in argRow(arg, schema) }
                }
                if !schema.isLeaf(f.type) {
                    HStack {
                        section("Fields to return", hint: "Tick what you want back")
                        Spacer()
                        Button("Defaults") { selection = GraphQL.defaultSelection(for: f, in: schema) }
                        Button("None") { selection = [] }
                    }
                    .buttonStyle(.borderless).font(.caption)
                    FieldTree(schema: schema, ref: f.type, prefix: "", depth: 0, selection: $selection)
                        .padding(8)
                        .surface()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, hint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(hint).font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func argRow(_ arg: GQLInputValue, _ schema: GQLSchema) -> some View {
        let binding = Binding(get: { args[arg.name] ?? "" }, set: { args[arg.name] = $0 })
        let named = schema.type(arg.type.name)
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 2) {
                    Text(arg.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                    if arg.type.isNonNull { Text("*").foregroundStyle(.red) }
                }
                Text(arg.type.display).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .frame(width: 130, alignment: .trailing)
            .help(arg.description ?? "")
            if named?.kind == .enumType, !arg.type.isList {
                SoftMenu(items: [""] + (named?.enumValues ?? []), selection: binding, title: { $0.isEmpty ? "—" : $0 })
            } else if arg.type.name == "Boolean", !arg.type.isList {
                SoftMenu(items: ["", "true", "false"], selection: binding, title: { $0.isEmpty ? "—" : $0 })
            } else {
                TextField(GraphQL.placeholder(for: arg, in: schema), text: binding)
                    .textFieldStyle(.soft)
                    .font(Theme.mono)
            }
        }
    }

    // Right: live preview
    private func preview(_ f: GQLField, _ schema: GQLSchema) -> some View {
        let built = GraphQL.buildOperation(op, field: f, selection: selection, args: args, schema: schema)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Preview").font(.subheadline.weight(.semibold))
            CodeTextView(text: .constant(built.query), editable: false, highlightGraphQL: true).surface()
            Text("Variables").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            CodeTextView(text: .constant(built.variables), editable: false, highlightJSON: true)
                .surface()
                .frame(height: 110)
        }
        .padding(12)
    }

    private func choose(_ f: GQLField, _ schema: GQLSchema) {
        field = f
        args = [:]
        selection = GraphQL.defaultSelection(for: f, in: schema)
    }

    private func apply(send: Bool) {
        guard let f = field, let schema = store.currentSchema else { return }
        let built = GraphQL.buildOperation(op, field: f, selection: selection, args: args, schema: schema)
        store.useGraphQL(query: built.query, variables: built.variables)
        if store.current.name.isEmpty { store.current.name = GraphQL.operationName(in: built.query) ?? f.name }
        dismiss()
        if send { store.send() }
    }
}

/// Checkbox tree of the fields of a type. Children render only when expanded, so recursive schemas are fine.
private struct FieldTree: View {
    let schema: GQLSchema
    let ref: GQLTypeRef
    let prefix: String
    let depth: Int
    @Binding var selection: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if schema.type(ref.name)?.kind == .union || schema.type(ref.name)?.kind == .interface {
                ForEach(schema.type(ref.name)?.possibleTypes ?? [], id: \.self) { t in
                    Branch(title: "on \(t)", typeLabel: "", path: path("on:\(t)"), depth: depth, selection: $selection) {
                        FieldTree(schema: schema, ref: .named(t), prefix: path("on:\(t)"), depth: depth + 1, selection: $selection)
                    }
                }
            }
            ForEach(schema.fields(of: ref).filter { !$0.isDeprecated }) { f in
                let p = path(f.name)
                let needsArgs = f.args.contains { $0.type.isNonNull }
                if schema.isLeaf(f.type) {
                    Toggle(isOn: Binding(
                        get: { selection.contains(p) },
                        set: { on in if on { selection.insert(p) } else { selection.remove(p) } }
                    )) {
                        HStack(spacing: 6) {
                            Text(f.name).font(.system(size: 12, design: .monospaced))
                            Text(f.type.display).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(needsArgs)
                    .help(needsArgs ? "Needs arguments — write this one by hand" : (f.description ?? ""))
                } else if depth < 6 {
                    Branch(title: f.name, typeLabel: f.type.display, path: p, depth: depth, selection: $selection) {
                        FieldTree(schema: schema, ref: f.type, prefix: p, depth: depth + 1, selection: $selection)
                    }
                    .disabled(needsArgs)
                }
            }
        }
    }

    private func path(_ segment: String) -> String { prefix.isEmpty ? segment : "\(prefix).\(segment)" }
}

private struct Branch<Content: View>: View {
    let title: String
    let typeLabel: String
    let path: String
    let depth: Int
    @Binding var selection: Set<String>
    @ViewBuilder let content: () -> Content
    @State private var expanded = false

    var body: some View {
        let count = selection.filter { $0.hasPrefix(path + ".") }.count
        DisclosureGroup(isExpanded: $expanded) {
            content().padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(typeLabel).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Theme.accent.opacity(0.2)))
                }
            }
        }
        .onAppear { if count > 0 { expanded = true } }
    }
}

// MARK: - Response errors

/// GraphQL often answers 200 OK with an `errors` array — make that impossible to miss.
struct GraphQLErrorsBanner: View {
    let messages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("GraphQL returned \(messages.count) error\(messages.count == 1 ? "" : "s")", systemImage: "exclamationmark.octagon.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            ForEach(Array(messages.prefix(3).enumerated()), id: \.offset) { _, m in
                Text("• " + m).font(.caption).textSelection(.enabled).lineLimit(3)
            }
            if messages.count > 3 { Text("…and \(messages.count - 3) more in the body").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color.red.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Color.red.opacity(0.25)))
    }
}
