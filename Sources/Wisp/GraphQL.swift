import AppKit

// MARK: - Schema model

enum GQLOperation: String, CaseIterable, Identifiable {
    case query = "Query", mutation = "Mutation"
    var id: String { rawValue }
    var keyword: String { rawValue.lowercased() }
}

indirect enum GQLTypeRef: Hashable {
    case named(String), list(GQLTypeRef), nonNull(GQLTypeRef)

    /// Innermost named type.
    var name: String {
        switch self {
        case .named(let n): return n
        case .list(let r), .nonNull(let r): return r.name
        }
    }
    /// GraphQL notation, e.g. `[User!]!`.
    var display: String {
        switch self {
        case .named(let n): return n
        case .list(let r): return "[\(r.display)]"
        case .nonNull(let r): return "\(r.display)!"
        }
    }
    var isNonNull: Bool { if case .nonNull = self { return true }; return false }
    var isList: Bool {
        switch self {
        case .named: return false
        case .list: return true
        case .nonNull(let r): return r.isList
        }
    }
    /// Strips an outer NON_NULL.
    var nullable: GQLTypeRef { if case .nonNull(let r) = self { return r }; return self }
}

enum GQLTypeKind: String {
    case scalar = "SCALAR", object = "OBJECT", interface = "INTERFACE", union = "UNION", enumType = "ENUM", inputObject = "INPUT_OBJECT"
}

struct GQLInputValue: Hashable, Identifiable {
    var name: String
    var description: String?
    var type: GQLTypeRef
    var defaultValue: String?
    var id: String { name }
    /// Non-null with no default: the server insists on a value.
    var isRequired: Bool { type.isNonNull && defaultValue == nil }
}

struct GQLField: Hashable, Identifiable {
    var name: String
    var description: String?
    var args: [GQLInputValue]
    var type: GQLTypeRef
    var isDeprecated: Bool
    var id: String { name }
}

struct GQLType: Hashable {
    var name: String
    var kind: GQLTypeKind
    var description: String?
    var fields: [GQLField]
    var inputFields: [GQLInputValue]
    var enumValues: [String]
    var possibleTypes: [String]
}

struct GQLSchema {
    var queryType: String?
    var mutationType: String?
    var types: [String: GQLType]

    func rootFields(_ op: GQLOperation) -> [GQLField] {
        let root = op == .query ? queryType : mutationType
        guard let root, let t = types[root] else { return [] }
        return t.fields.sorted { $0.name < $1.name }
    }
    func type(_ name: String) -> GQLType? { types[name] }
    func isLeaf(_ ref: GQLTypeRef) -> Bool {
        guard let t = types[ref.name] else { return true }
        return t.kind == .scalar || t.kind == .enumType
    }
    func fields(of ref: GQLTypeRef) -> [GQLField] {
        guard let t = types[ref.name], t.kind == .object || t.kind == .interface else { return [] }
        return t.fields
    }
    var typeCount: Int { types.keys.filter { !$0.hasPrefix("__") }.count }
}

struct GraphQLSchemaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Engine

enum GraphQL {
    static let introspectionQuery = """
    query IntrospectionQuery {
      __schema {
        queryType { name }
        mutationType { name }
        subscriptionType { name }
        types { ...FullType }
      }
    }

    fragment FullType on __Type {
      kind
      name
      description
      fields(includeDeprecated: true) {
        name
        description
        args { ...InputValue }
        type { ...TypeRef }
        isDeprecated
        deprecationReason
      }
      inputFields { ...InputValue }
      interfaces { ...TypeRef }
      enumValues(includeDeprecated: true) { name description isDeprecated deprecationReason }
      possibleTypes { ...TypeRef }
    }

    fragment InputValue on __InputValue {
      name
      description
      type { ...TypeRef }
      defaultValue
    }

    fragment TypeRef on __Type {
      kind name ofType { kind name ofType { kind name ofType { kind name ofType {
        kind name ofType { kind name ofType { kind name ofType { kind name } } } } } } }
    }
    """

    // MARK: Schema parsing

    static func parseSchema(_ data: Data) throws -> GQLSchema {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GraphQLSchemaError(message: "The response isn't JSON, so this doesn't look like a GraphQL endpoint.")
        }
        let schemaJSON = (root["data"] as? [String: Any])?["__schema"] as? [String: Any] ?? root["__schema"] as? [String: Any]
        guard let s = schemaJSON else {
            let msgs = errors(in: data)
            if let first = msgs.first {
                let all = msgs.joined(separator: "; ")
                if first.lowercased().contains("introspection") {
                    throw GraphQLSchemaError(message: "Introspection is disabled on this server: \(all)")
                }
                throw GraphQLSchemaError(message: "The server rejected the schema request: \(all)")
            }
            throw GraphQLSchemaError(message: "The response doesn't contain a GraphQL schema (no data.__schema). Is this a GraphQL endpoint?")
        }
        func rootName(_ k: String) -> String? { (s[k] as? [String: Any])?["name"] as? String }
        var types: [String: GQLType] = [:]
        for t in s["types"] as? [[String: Any]] ?? [] {
            guard let name = t["name"] as? String,
                  let kind = GQLTypeKind(rawValue: t["kind"] as? String ?? "") else { continue }
            let fields: [GQLField] = (t["fields"] as? [[String: Any]] ?? []).compactMap { f in
                guard let n = f["name"] as? String, let ty = typeRef(f["type"]) else { return nil }
                return GQLField(name: n, description: f["description"] as? String,
                                args: inputValues(f["args"]), type: ty,
                                isDeprecated: f["isDeprecated"] as? Bool ?? false)
            }
            types[name] = GQLType(
                name: name, kind: kind, description: t["description"] as? String, fields: fields,
                inputFields: inputValues(t["inputFields"]),
                enumValues: (t["enumValues"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                possibleTypes: (t["possibleTypes"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        }
        return GQLSchema(queryType: rootName("queryType"), mutationType: rootName("mutationType"), types: types)
    }

    private static func typeRef(_ any: Any?) -> GQLTypeRef? {
        guard let d = any as? [String: Any] else { return nil }
        switch d["kind"] as? String {
        case "NON_NULL": return typeRef(d["ofType"]).map { .nonNull($0) }
        case "LIST": return typeRef(d["ofType"]).map { .list($0) }
        default: return (d["name"] as? String).map { .named($0) }
        }
    }

    private static func inputValues(_ any: Any?) -> [GQLInputValue] {
        (any as? [[String: Any]] ?? []).compactMap { a in
            guard let n = a["name"] as? String, let ty = typeRef(a["type"]) else { return nil }
            return GQLInputValue(name: n, description: a["description"] as? String, type: ty,
                                 defaultValue: a["defaultValue"] as? String)
        }
    }

    // MARK: Default selection

    static func defaultSelection(for field: GQLField, in schema: GQLSchema) -> Set<String> {
        Set(defaultPaths(for: field.type, in: schema, descend: true))
    }

    private static let preferredLeaves = ["id", "name", "title", "code", "email"]

    private static func pickLeaves(_ fields: [GQLField], _ schema: GQLSchema, cap: Int) -> [String] {
        let leaves = fields.filter { schema.isLeaf($0.type) && !$0.isDeprecated && !$0.args.contains(where: \.isRequired) }
            .map(\.name)
        let preferred = preferredLeaves.filter(leaves.contains)
        return Array((preferred + leaves.filter { !preferred.contains($0) }).prefix(cap))
    }

    private static func defaultPaths(for ref: GQLTypeRef, in schema: GQLSchema, descend: Bool) -> [String] {
        if schema.isLeaf(ref) { return [] }
        if let t = schema.type(ref.name), t.kind == .union {
            return t.possibleTypes.prefix(6).flatMap { member in
                pickLeaves(schema.fields(of: .named(member)), schema, cap: 4).map { "on:\(member).\($0)" }
            }
        }
        let fields = schema.fields(of: ref)
        let leaves = pickLeaves(fields, schema, cap: 12)
        if !leaves.isEmpty || !descend { return leaves }
        guard let obj = fields.first(where: { !schema.isLeaf($0.type) && !$0.isDeprecated && !$0.args.contains(where: \.isRequired) })
        else { return [] }
        return defaultPaths(for: obj.type, in: schema, descend: false).map { "\(obj.name).\($0)" }
    }

    // MARK: Operation building

    private struct SelTree {
        var kids: [String: SelTree] = [:]
        init(_ paths: some Sequence<String> = [String]()) {
            for p in paths { insert(p.split(separator: ".").map(String.init)[...]) }
        }
        mutating func insert(_ parts: ArraySlice<String>) {
            guard let head = parts.first, !head.isEmpty else { return }
            kids[head, default: SelTree()].insert(parts.dropFirst())
        }
    }

    static func buildOperation(_ op: GQLOperation, field: GQLField, selection: Set<String>, args: [String: String],
                               schema: GQLSchema) -> (query: String, variables: String) {
        let used = field.args.filter { a in
            a.type.isNonNull || !(args[a.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let varDefs = used.map { "$\($0.name): \($0.type.display)" }.joined(separator: ", ")
        let fieldArgs = used.map { "\($0.name): $\($0.name)" }.joined(separator: ", ")

        var lines = ["\(op.keyword) \(operationName(op, field.name))\(varDefs.isEmpty ? "" : "(\(varDefs))") {"]
        let call = "  \(field.name)\(fieldArgs.isEmpty ? "" : "(\(fieldArgs))")"
        if schema.isLeaf(field.type) {
            lines.append(call)
        } else {
            let tree = SelTree(selection.isEmpty ? defaultSelection(for: field, in: schema) : selection)
            let inner = render(tree, on: field.type, schema, depth: 2)
            lines.append(call + " {")
            lines += inner.isEmpty ? ["    __typename"] : inner
            lines.append("  }")
        }
        lines.append("}")

        let pairs = used.map { a in "\(jsonString(a.name)):\(jsonValue(args[a.name] ?? "", a.type, schema))" }
        let compact = "{" + pairs.joined(separator: ",") + "}"
        return (lines.joined(separator: "\n"), JSONFormat.pretty(compact) ?? compact)
    }

    private static func operationName(_ op: GQLOperation, _ fieldName: String) -> String {
        let pascal = fieldName.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        guard op == .query else { return pascal }
        let lower = fieldName.lowercased()
        if lower.hasPrefix("get"), fieldName.dropFirst(3).first?.isUppercase == true { return pascal }
        return "Get" + pascal
    }

    private static func render(_ tree: SelTree, on ref: GQLTypeRef, _ schema: GQLSchema, depth: Int) -> [String] {
        let pad = String(repeating: "  ", count: depth)
        let t = schema.type(ref.name)
        var kids = tree.kids
        var out: [String] = []
        let fragments = kids.keys.filter { $0.hasPrefix("on:") }
        if t?.kind == .union || (!fragments.isEmpty && t?.kind == .interface) {
            out.append(pad + "__typename")
            kids["__typename"] = nil
        }
        let known = (t?.fields ?? []).map(\.name).filter { kids[$0] != nil }
        let unknown = kids.keys.filter { !$0.hasPrefix("on:") && !known.contains($0) }.sorted()
        for name in known + unknown {
            let sub = kids[name]!
            let f = t?.fields.first { $0.name == name }
            if let f, !schema.isLeaf(f.type) {
                let tree = sub.kids.isEmpty ? SelTree(defaultPaths(for: f.type, in: schema, descend: true)) : sub
                out += block(pad + name, render(tree, on: f.type, schema, depth: depth + 1), pad)
            } else if f == nil, !sub.kids.isEmpty {
                out += block(pad + name, render(sub, on: .named(""), schema, depth: depth + 1), pad)
            } else {
                out.append(pad + name)
            }
        }
        let order = t?.possibleTypes ?? []
        for key in fragments.sorted(by: { a, b in
            let ia = order.firstIndex(of: String(a.dropFirst(3))) ?? .max, ib = order.firstIndex(of: String(b.dropFirst(3))) ?? .max
            return ia == ib ? a < b : ia < ib
        }) {
            let member = String(key.dropFirst(3))
            var sub = kids[key]!
            if sub.kids.isEmpty { sub = SelTree(defaultPaths(for: .named(member), in: schema, descend: true)) }
            out += block(pad + "... on \(member)", render(sub, on: .named(member), schema, depth: depth + 1), pad)
        }
        return out
    }

    private static func block(_ head: String, _ inner: [String], _ pad: String) -> [String] {
        [head + " {"] + (inner.isEmpty ? [pad + "  __typename"] : inner) + [pad + "}"]
    }

    // MARK: Values

    private static func jsonString(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return d.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func parsedJSON(_ s: String) -> Any? {
        s.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
    }

    /// Converts user-typed text to a JSON literal according to the argument's GraphQL type.
    private static func jsonValue(_ raw: String, _ ref: GQLTypeRef, _ schema: GQLSchema) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return sampleJSON(ref, schema, depth: 0) }
        let quoted = parsedJSON(t) is String  // user typed "IN" with quotes
        if ref.isList { return parsedJSON(t) != nil ? t : jsonString(t) }
        let kind = schema.type(ref.name)?.kind
        switch ref.name {
        case "Int": return Int(t) != nil ? t : jsonString(t)
        case "Float": return Double(t) != nil && parsedJSON(t) is NSNumber ? t : jsonString(t)
        case "Boolean":
            switch t.lowercased() {
            case "true", "yes", "1": return "true"
            case "false", "no", "0": return "false"
            default: return jsonString(t)
            }
        default: break
        }
        if kind == .enumType { return quoted ? t : jsonString(t) }
        if kind == .inputObject { return parsedJSON(t) is [String: Any] ? t : jsonString(t) }
        if quoted { return t }
        if kind == .scalar, !["String", "ID"].contains(ref.name), t.first == "{" || t.first == "[", parsedJSON(t) != nil { return t }
        return jsonString(raw)
    }

    /// A well-formed sample JSON value for an empty required argument (or an input-object skeleton).
    private static func sampleJSON(_ ref: GQLTypeRef, _ schema: GQLSchema, depth: Int) -> String {
        if ref.isList { return "[]" }
        switch ref.name {
        case "Int", "Float": return "0"
        case "Boolean": return "false"
        default: break
        }
        guard let t = schema.type(ref.name) else { return "\"\"" }
        switch t.kind {
        case .enumType: return jsonString(t.enumValues.first ?? "")
        case .inputObject:
            guard depth < 3 else { return "{}" }
            let req = t.inputFields.filter(\.isRequired)
            let shown = req.isEmpty ? Array(t.inputFields.prefix(depth == 0 ? 3 : 0)) : req
            return "{" + shown.map { "\(jsonString($0.name)):\(sampleJSON($0.type, schema, depth: depth + 1))" }
                .joined(separator: ",") + "}"
        default: return "\"\""
        }
    }

    static func placeholder(for arg: GQLInputValue, in schema: GQLSchema) -> String {
        let suffix = arg.defaultValue.map { " (default: \($0))" } ?? ""
        let ref = arg.type.nullable
        let hint: String
        if ref.isList {
            let inner = GQLInputValue(name: arg.name, type: listElement(ref), defaultValue: nil)
            let el = placeholder(for: inner, in: schema).replacingOccurrences(of: "e.g. ", with: "")
            hint = el.hasPrefix("one of") ? "JSON list, \(el)" : "e.g. [\(el)]"
        } else {
            switch (ref.name, schema.type(ref.name)?.kind) {
            case ("Int", _): hint = "e.g. 42"
            case ("Float", _): hint = "e.g. 9.99"
            case ("Boolean", _): hint = "true or false"
            case ("ID", _): hint = "e.g. \"1\""
            case ("String", _): hint = "e.g. \"text\""
            case (_, .enumType?):
                let vals = schema.type(ref.name)!.enumValues
                hint = "one of: " + vals.prefix(6).joined(separator: ", ") + (vals.count > 6 ? ", …" : "")
            case (_, .inputObject?): hint = sampleJSON(ref, schema, depth: 0)
            default: hint = "e.g. \"…\" (\(ref.name))"
            }
        }
        return hint + suffix
    }

    private static func listElement(_ ref: GQLTypeRef) -> GQLTypeRef {
        switch ref {
        case .list(let r): return r
        case .nonNull(let r): return listElement(r)
        case .named: return ref
        }
    }

    // MARK: Request / response helpers

    static func requestBody(query: String, variables: String) -> String {
        var parts = ["\"query\":\(jsonString(query))"]
        let v = variables.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty, parsedJSON(v) is [String: Any] { parts.append("\"variables\":\(v)") }
        if let name = operationName(in: query) { parts.append("\"operationName\":\(jsonString(name))") }
        let compact = "{" + parts.joined(separator: ",") + "}"
        return JSONFormat.pretty(compact) ?? compact
    }

    static func errors(in responseBody: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let errs = root["errors"] as? [Any] else { return [] }
        return errs.compactMap { e -> String? in
            if let s = e as? String { return s }
            guard let d = e as? [String: Any] else { return nil }
            var msg = d["message"] as? String ?? "Unknown error"
            let locs = (d["locations"] as? [[String: Any]] ?? []).compactMap { l -> String? in
                guard let line = l["line"] as? Int else { return nil }
                return "\(line):\(l["column"] as? Int ?? 0)"
            }
            if !locs.isEmpty { msg += " (line \(locs.joined(separator: ", ")))" }
            if let path = d["path"] as? [Any], !path.isEmpty { msg += " at " + path.map { "\($0)" }.joined(separator: ".") }
            return msg
        }
    }

    static func looksLikeGraphQLResponse(_ responseBody: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] else { return false }
        return root["data"] != nil || root["errors"] != nil
    }

    // MARK: Tokenizer

    private enum TokKind { case name, variable, directive, number, string, punct, spread, comment }
    private struct Tok: Equatable {
        var kind: TokKind
        var text: String
        var ownLine = false  // comments only: preceded by a line break
        var isValueStart: Bool { [.name, .variable, .number, .string].contains(kind) || text == "[" || text == "{" }
        var isValueEnd: Bool { [.name, .variable, .number, .string].contains(kind) || ["]", "}", "!"].contains(text) }
    }

    /// Lexes a GraphQL document. Commas are insignificant and dropped. Returns nil on unknown input.
    private static func tokenize(_ src: String) -> [Tok]? {
        let s = Array(src.unicodeScalars)
        var toks: [Tok] = []
        var i = 0
        var sawNewline = true
        func isNameStart(_ c: Unicode.Scalar) -> Bool { c == "_" || (c.isASCII && c.properties.isAlphabetic) }
        func isNameChar(_ c: Unicode.Scalar) -> Bool { isNameStart(c) || ("0"..."9").contains(c) }
        func text(_ a: Int, _ b: Int) -> String { String(String.UnicodeScalarView(s[a..<b])) }
        func scanName(_ from: Int) -> Int { var j = from; while j < s.count, isNameChar(s[j]) { j += 1 }; return j }
        func at(_ k: Int, _ str: String) -> Bool {
            let u = Array(str.unicodeScalars)
            return k + u.count <= s.count && Array(s[k..<k + u.count]) == u
        }
        while i < s.count {
            let c = s[i]
            if c == "\n" || c == "\r" { sawNewline = true; i += 1; continue }
            if c == " " || c == "\t" || c == "," || c == "\u{FEFF}" { i += 1; continue }
            let start = i
            if c == "#" {
                while i < s.count, s[i] != "\n", s[i] != "\r" { i += 1 }
                toks.append(Tok(kind: .comment, text: text(start, i), ownLine: sawNewline))
            } else if at(i, "\"\"\"") {
                i += 3
                while i < s.count, !at(i, "\"\"\"") { i += at(i, "\\\"\"\"") ? 4 : 1 }
                guard i < s.count else { return nil }
                i += 3
                toks.append(Tok(kind: .string, text: text(start, i)))
            } else if c == "\"" {
                i += 1
                while i < s.count, s[i] != "\"" {
                    if s[i] == "\n" || s[i] == "\r" { return nil }
                    i += s[i] == "\\" ? 2 : 1
                }
                guard i < s.count else { return nil }
                i += 1
                toks.append(Tok(kind: .string, text: text(start, i)))
            } else if at(i, "...") {
                i += 3
                toks.append(Tok(kind: .spread, text: "..."))
            } else if c == "$" || c == "@" {
                guard i + 1 < s.count, isNameStart(s[i + 1]) else { return nil }
                i = scanName(i + 1)
                toks.append(Tok(kind: c == "$" ? .variable : .directive, text: text(start, i)))
            } else if isNameStart(c) {
                i = scanName(i)
                toks.append(Tok(kind: .name, text: text(start, i)))
            } else if c == "-" || ("0"..."9").contains(c) {
                i += 1
                while i < s.count, ("0"..."9").contains(s[i]) || s[i] == "." || s[i] == "e" || s[i] == "E"
                        || ((s[i] == "+" || s[i] == "-") && (s[i - 1] == "e" || s[i - 1] == "E")) { i += 1 }
                toks.append(Tok(kind: .number, text: text(start, i)))
            } else if "{}()[]:=!|&".unicodeScalars.contains(c) {
                i += 1
                toks.append(Tok(kind: .punct, text: String(c)))
            } else {
                return nil
            }
            sawNewline = false
        }
        return toks
    }

    // MARK: Formatting

    static func format(_ query: String) -> String {
        guard let toks = tokenize(query), !toks.isEmpty, let out = layout(toks),
              tokenize(out)?.map(\.text) == toks.map(\.text) else { return query }
        return out
    }

    private enum Ctx { case block, inlineBrace, paren, bracket }

    private static func layout(_ toks: [Tok]) -> String? {
        var lines: [String] = []
        var cur = "", curIndent = 0
        var stack: [Ctx] = []
        var prev: Tok?
        var prevIsOnKeyword = false
        var blankPending = false
        var depth: Int { stack.filter { $0 == .block }.count }
        func flush() {
            if !cur.isEmpty { lines.append(String(repeating: "  ", count: curIndent) + cur) }
            cur = ""
        }
        func put(_ t: String, _ sep: String) {
            if cur.isEmpty { curIndent = depth } else { cur += sep }
            cur += t
        }
        func separator(_ p: Tok?, _ c: Tok, inline: Bool) -> String {
            guard let p else { return "" }
            if [")", "]", "!", ":", "("].contains(c.text) || ["(", "["].contains(p.text) { return "" }
            if p.text == "{" && c.text == "}" { return "" }
            if p.kind == .spread { return c.text == "on" || c.kind == .directive ? " " : "" }
            if inline && p.isValueEnd && c.isValueStart { return ", " }
            return " "
        }
        for t in toks {
            let inline = stack.last.map { $0 != .block } ?? false
            if blankPending { flush(); lines.append(""); blankPending = false }
            defer {
                prevIsOnKeyword = t.text == "on" && prev?.kind == .spread
                prev = t
            }
            if t.kind == .comment {
                if t.ownLine { flush() }
                put(t.text, " ")
                flush()
                continue
            }
            switch t.text {
            case "{" where !inline:
                put("{", " "); flush(); stack.append(.block)
            case "}" where stack.last == .block:
                stack.removeLast(); flush(); put("}", ""); flush()
                if stack.isEmpty { blankPending = true }
            case "}", ")", "]":
                let want: Ctx = t.text == "}" ? .inlineBrace : t.text == ")" ? .paren : .bracket
                guard stack.last == want else { return nil }
                stack.removeLast()
                put(t.text, separator(prev, t, inline: true))
            default:
                if stack.last == .block, !cur.isEmpty, t.kind == .name || t.kind == .spread, let p = prev,
                   (p.kind == .name && !prevIsOnKeyword) || p.kind == .directive || p.text == ")" {
                    flush()
                }
                put(t.text, separator(prev, t, inline: inline))
                switch t.text {
                case "{": stack.append(.inlineBrace)
                case "(": stack.append(.paren)
                case "[": stack.append(.bracket)
                default: break
                }
            }
        }
        flush()
        guard stack.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    static func operationName(in query: String) -> String? {
        guard let toks = tokenize(query)?.filter({ $0.kind != .comment }) else { return nil }
        var depth = 0
        for (i, t) in toks.enumerated() {
            if "{([".contains(t.text) { depth += 1 } else if "})]".contains(t.text) { depth -= 1 }
            if depth == 0, t.kind == .name, ["query", "mutation", "subscription"].contains(t.text),
               i + 1 < toks.count, toks[i + 1].kind == .name { return toks[i + 1].text }
        }
        return nil
    }
}

// MARK: - Syntax highlighting

extension GraphQL {
    private static let hlRules: [(NSRegularExpression, NSColor, Int)] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        return [
            (re(#"(?<![\w$])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#), .systemPurple, 0),
            (re(#"\b(?:query|mutation|subscription|fragment|on|true|false|null)\b"#), .systemPink, 0),
            (re(#"\$[_A-Za-z]\w*\s*:\s*[\[\s]*([_A-Za-z]\w*)"#), .systemTeal, 1),
            (re(#"\bon\s+([_A-Za-z]\w*)"#), .systemTeal, 1),
            (re(#"\$[_A-Za-z]\w*"#), .systemPurple, 0),
        ]
    }()
    private static let hlStringsComments = try! NSRegularExpression(pattern: #"("""[\s\S]*?"""|"(?:[^"\\\n]|\\.)*")|(#[^\n]*)"#)

    static func highlight(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length <= 300_000 else { return }
        let text = storage.string
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
        for (regex, color, group) in hlRules {
            for m in regex.matches(in: text, range: full) where m.range(at: group).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: color, range: m.range(at: group))
            }
        }
        for m in hlStringsComments.matches(in: text, range: full) {
            let isString = m.range(at: 1).location != NSNotFound
            storage.addAttribute(.foregroundColor, value: isString ? NSColor.systemOrange : NSColor.secondaryLabelColor,
                                 range: m.range)
        }
        storage.endEditing()
    }
}
