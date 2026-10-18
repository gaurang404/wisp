import Foundation

struct ImportResult {
    var name: String                 // collection/API title
    var requests: [RequestSpec]      // each with .folder, .name, .docs (markdown)
    var variables: [KeyValue]        // suggested env vars, e.g. baseUrl, token, apiKey placeholders
    var format: String               // "OpenAPI 3.0", "Swagger 2.0", "Postman v2.1", "Insomnia", "HAR", "cURL"
}

enum ImportError: LocalizedError {
    case unrecognized, invalid(String)

    var errorDescription: String? {
        switch self {
        case .unrecognized:
            return "Unrecognized format. Supported: OpenAPI 3, Swagger 2, Postman v2, Insomnia v4, HAR and cURL."
        case .invalid(let msg):
            return msg
        }
    }
}

enum Importer {
    static func parse(_ data: Data) throws -> ImportResult {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return try parse(text: text)
    }

    static func parse(text: String) throws -> ImportResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard !trimmed.isEmpty else { throw ImportError.invalid("The file is empty.") }

        let root: Any
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            // JSON is valid YAML; our parser keeps key order. Fall back to Foundation for odd edge cases.
            if let v = try? YAML.parse(trimmed, keepOrder: true) {
                root = v
            } else if let v = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) {
                root = v
            } else {
                throw ImportError.invalid("The file looks like JSON but could not be parsed.")
            }
        } else if CurlImporter.looksLikeCurl(trimmed) {
            return try CurlImporter.parse(trimmed)
        } else {
            do { root = try YAML.parse(trimmed, keepOrder: true) }
            catch { throw ImportError.unrecognized }
        }

        guard let d = root as? [String: Any] else { throw ImportError.unrecognized }
        let result: ImportResult
        if d["openapi"] != nil || d["swagger"] != nil {
            var imp = OpenAPIImporter(root: d)
            result = try imp.run()
        } else if let info = d["info"] as? [String: Any], d["item"] is [Any] || info["_postman_id"] != nil
                    || (J.str(info["schema"]) ?? "").contains("postman") {
            var imp = PostmanImporter(root: d)
            result = imp.run()
        } else if J.str(d["_type"]) == "export", d["resources"] is [Any] {
            result = InsomniaImporter(root: d).run()
        } else if let log = d["log"] as? [String: Any], log["entries"] is [Any] {
            result = HARImporter(log: log).run()
        } else {
            throw ImportError.unrecognized
        }
        if result.requests.isEmpty { throw ImportError.invalid("No requests found in this \(result.format) file.") }
        return result
    }
}

// MARK: - JSON helpers

private enum J {
    typealias Dict = [String: Any]

    static func str(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return isBool(n) ? (n.boolValue ? "true" : "false") : n.stringValue
        default: return nil
        }
    }

    static func bool(_ v: Any?) -> Bool {
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s == "true" }
        return false
    }

    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    static func dicts(_ v: Any?) -> [Dict] { (v as? [Any])?.compactMap { $0 as? Dict } ?? [] }

    /// A dictionary that remembers key order for `serialize`.
    static func ordered(_ pairs: [(String, Any)]) -> Dict {
        var d: Dict = [:]
        var order: [String] = []
        for (k, v) in pairs where d[k] == nil { d[k] = v; order.append(k) }
        d[YAML.orderKey] = order
        return d
    }

    /// Pretty JSON (2-space indent, key order preserved, no escaped slashes) matching JSONFormat.pretty style.
    static func serialize(_ v: Any, level: Int = 0) -> String {
        let pad = String(repeating: "  ", count: level + 1), end = String(repeating: "  ", count: level)
        switch v {
        case let d as Dict:
            let keys = YAML.keys(d)
            if keys.isEmpty { return "{}" }
            return "{\n" + keys.map { pad + quote($0) + ": " + serialize(d[$0]!, level: level + 1) }.joined(separator: ",\n") + "\n" + end + "}"
        case let a as [Any]:
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { pad + serialize($0, level: level + 1) }.joined(separator: ",\n") + "\n" + end + "]"
        case let s as String:
            return quote(s)
        case let n as NSNumber:
            if isBool(n) { return n.boolValue ? "true" : "false" }
            let t = String(cString: n.objCType)
            if t == "d" || t == "f" {
                let d = n.doubleValue
                guard d.isFinite else { return "null" }
                if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
                return "\(d)"
            }
            return n.stringValue
        default:
            return "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// Scalar → string for form fields / params; collections → compact-ish JSON.
    static func text(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "" }
        if let s = str(v) { return s }
        return serialize(v)
    }

    /// Pretty-prints JSON text if it is strictly valid JSON, else returns it unchanged (e.g. templated `{{n}}` bodies).
    static func prettyBody(_ s: String) -> String {
        JSONFormat.pretty(s) ?? s
    }

    static func looksLikeJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]"))
    }
}

/// Ordered, de-duplicated variable list.
private struct VarBag {
    private(set) var items: [KeyValue] = []

    mutating func add(_ key: String, _ value: String = "") {
        guard !key.isEmpty else { return }
        if let i = items.firstIndex(where: { $0.key == key }) {
            if items[i].value.isEmpty, !value.isEmpty { items[i].value = value }
        } else {
            items.append(KeyValue(key: key, value: value))
        }
    }
}

private func method(_ s: String?) -> HTTPMethod {
    HTTPMethod(rawValue: (s ?? "GET").uppercased()) ?? .GET
}

private func regexReplace(_ s: String, _ pattern: String, _ template: String) -> String {
    s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
}

/// `:id` path segments → `{{id}}` (skips the scheme/port colons).
private func colonParamsToVars(_ url: String) -> String {
    regexReplace(url, #"(?<=/):([A-Za-z_][A-Za-z0-9_\-]*)"#, "{{$1}}")
}

private func hostOf(_ url: String) -> String {
    URLComponents(string: url)?.host ?? ""
}

// MARK: - OpenAPI 3.x / Swagger 2.0

private struct OpenAPIImporter {
    let root: J.Dict
    let isV2: Bool
    var vars = VarBag()

    init(root: J.Dict) {
        self.root = root
        self.isV2 = root["swagger"] != nil
    }

    static let methods = ["get", "put", "post", "delete", "options", "head", "patch"]

    var format: String {
        if isV2 { return "Swagger " + (J.str(root["swagger"]) ?? "2.0") }
        let v = J.str(root["openapi"]) ?? "3.0"
        let parts = v.split(separator: ".")
        return "OpenAPI " + (parts.count >= 2 ? "\(parts[0]).\(parts[1])" : v)
    }

    mutating func run() throws -> ImportResult {
        let info = root["info"] as? J.Dict ?? [:]
        let title = (J.str(info["title"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? "API" : title
        vars.add("baseUrl", baseURL())

        guard let paths = root["paths"] as? J.Dict else { throw ImportError.invalid("The \(format) document has no paths.") }
        var requests: [RequestSpec] = []
        for path in YAML.keys(paths) {
            guard let item = resolve(paths[path]) else { continue }
            let common = J.dicts(item["parameters"])
            for key in YAML.keys(item) where Self.methods.contains(key.lowercased()) {
                guard let op = resolve(item[key]) else { continue }
                requests.append(request(path: path, method: key.uppercased(), op: op, common: common, title: name))
            }
        }
        return ImportResult(name: name, requests: requests, variables: vars.items, format: format)
    }

    // MARK: Refs

    func resolve(_ v: Any?, hops: Int = 0) -> J.Dict? {
        guard let d = v as? J.Dict else { return nil }
        guard let ref = J.str(d["$ref"]), hops < 32 else { return d }
        guard let target = lookup(ref) else { return d }
        return resolve(target, hops: hops + 1)
    }

    func lookup(_ ref: String) -> Any? {
        guard ref.hasPrefix("#/") else { return nil }
        var node: Any? = root
        for raw in ref.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let comp = (String(raw).removingPercentEncoding ?? String(raw))
                .replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let d = node as? J.Dict { node = d[comp] }
            else if let a = node as? [Any], let i = Int(comp), a.indices.contains(i) { node = a[i] }
            else { return nil }
        }
        return node
    }

    static func refName(_ d: J.Dict?) -> String? {
        guard let ref = J.str(d?["$ref"]) else { return nil }
        return ref.split(separator: "/").last.map(String.init)
    }

    // MARK: Base URL

    func baseURL() -> String {
        var url = ""
        if isV2 {
            let host = J.str(root["host"]) ?? ""
            let basePath = J.str(root["basePath"]) ?? ""
            if !host.isEmpty {
                let scheme = (root["schemes"] as? [Any])?.compactMap(J.str).first ?? "https"
                url = "\(scheme)://\(host)\(basePath)"
            } else {
                url = basePath
            }
        } else if let server = J.dicts(root["servers"]).first {
            url = J.str(server["url"]) ?? ""
            if let sv = server["variables"] as? J.Dict {
                for k in YAML.keys(sv) {
                    let def = J.str((sv[k] as? J.Dict)?["default"]) ?? ""
                    url = url.replacingOccurrences(of: "{\(k)}", with: def)
                }
            }
        }
        if !url.contains("://") {
            url = url.hasPrefix("//") ? "https:" + url : "http://localhost" + (url.isEmpty || url.hasPrefix("/") ? url : "/" + url)
        }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    // MARK: Operation

    struct Param {
        var name: String
        var location: String
        var required: Bool
        var schema: J.Dict?
        var description: String
        var example: Any?
        var raw: J.Dict
    }

    mutating func request(path: String, method m: String, op: J.Dict, common: [J.Dict], title: String) -> RequestSpec {
        var spec = RequestSpec()
        spec.method = method(m)
        let summary = J.str(op["summary"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let opId = J.str(op["operationId"]) ?? ""
        spec.name = !summary.isEmpty ? summary : !opId.isEmpty ? opId : "\(m) \(path)"
        if let tag = (op["tags"] as? [Any])?.compactMap(J.str).first, !tag.isEmpty {
            spec.folder = "\(title)/\(tag)"
        } else {
            spec.folder = title
        }

        // Parameters: path-level first, operation-level overrides by (name, in).
        var params: [Param] = []
        for raw in common + J.dicts(op["parameters"]) {
            guard let p = resolve(raw), let name = J.str(p["name"]) else { continue }
            let loc = (J.str(p["in"]) ?? "query").lowercased()
            var schema = resolve(p["schema"])
            if isV2, schema == nil || loc != "body" { schema = p }
            var example: Any? = p["example"] ?? p["x-example"]
            if example == nil, let ex = p["examples"] as? J.Dict, let first = YAML.keys(ex).first {
                example = resolve(ex[first])?["value"] ?? ex[first]
            }
            if example == nil, loc != "body", let s = schema.flatMap({ resolve($0) }) {
                example = s["example"] ?? s["default"] ?? (s["enum"] as? [Any])?.first
                if example == nil, let items = resolve(s["items"]) {
                    example = items["example"] ?? items["default"] ?? (items["enum"] as? [Any])?.first
                }
            }
            let param = Param(name: name, location: loc, required: J.bool(p["required"]) || loc == "path",
                              schema: schema, description: J.str(p["description"]) ?? "", example: example, raw: p)
            if let i = params.firstIndex(where: { $0.name == name && $0.location == loc }) { params[i] = param }
            else { params.append(param) }
        }

        var url = "{{baseUrl}}" + regexReplace(path, #"\{([^{}/]+)\}"#, "{{$1}}")
        var formFields: [KeyValue] = []
        var bodySchemaV2: J.Dict?
        for p in params {
            let value = J.text(p.example)
            switch p.location {
            case "path":
                if !path.contains("{\(p.name)}") { url = url.replacingOccurrences(of: ":\(p.name)", with: "{{\(p.name)}}") }
                vars.add(p.name, value)
            case "query":
                spec.params.append(KeyValue(enabled: p.required, key: p.name, value: value))
            case "header":
                spec.headers.append(KeyValue(enabled: p.required, key: p.name, value: value))
            case "body":
                bodySchemaV2 = p.schema
            case "formdata":
                if (J.str(p.raw["type"]) ?? "") != "file" {
                    let v = value.isEmpty ? J.text(sample(p.schema, depth: 0, stack: [])) : value
                    formFields.append(KeyValue(enabled: true, key: p.name, value: v))
                }
            default: break
            }
        }
        // Any remaining {x} placeholders not declared as parameters still become variables.
        for m in url.matches(of: #/\{\{([^{}]+)\}\}/#) where m.1 != "baseUrl" { vars.add(String(m.1)) }
        spec.url = url

        // Body
        var bodyHint = ""
        if isV2 {
            let consumes = ((op["consumes"] ?? root["consumes"]) as? [Any])?.compactMap(J.str) ?? []
            if let schema = bodySchemaV2 {
                spec.bodyKind = .json
                spec.body = J.serialize(sample(schema, depth: 0, stack: []))
                bodyHint = "`\(consumes.first { $0.contains("json") } ?? "application/json")` — \(typeName(schema))"
            } else if !formFields.isEmpty {
                spec.bodyKind = .form
                spec.form = formFields
                bodyHint = "`\(consumes.first ?? "application/x-www-form-urlencoded")` — form fields"
            }
        } else if let rb = resolve(op["requestBody"]) {
            bodyHint = applyBody(rb, to: &spec)
        }

        applySecurity(op: op, to: &spec)
        spec.docs = docs(spec: spec, path: path, method: m, summary: summary, op: op, params: params, bodyHint: bodyHint)
        return spec
    }

    /// OpenAPI 3 requestBody → body. Returns a markdown hint describing the body.
    mutating func applyBody(_ rb: J.Dict, to spec: inout RequestSpec) -> String {
        guard let content = rb["content"] as? J.Dict, !YAML.keys(content).isEmpty else { return "" }
        let types = YAML.keys(content)
        let chosen = types.first { $0.lowercased().hasPrefix("application/json") }
            ?? types.first { $0.lowercased().contains("json") }
            ?? types.first { $0.lowercased().contains("x-www-form-urlencoded") }
            ?? types.first { $0.lowercased().contains("multipart/form-data") }
            ?? types[0]
        let media = content[chosen] as? J.Dict ?? [:]
        let lower = chosen.lowercased()
        var example: Any? = media["example"]
        if example == nil, let ex = media["examples"] as? J.Dict, let first = YAML.keys(ex).first {
            example = resolve(ex[first])?["value"]
        }
        if lower.contains("x-www-form-urlencoded") || lower.contains("multipart/form-data") {
            spec.bodyKind = .form
            if let obj = (example as? J.Dict) {
                spec.form = YAML.keys(obj).map { KeyValue(key: $0, value: J.text(obj[$0])) }
            } else {
                let props = mergedProperties(media["schema"])
                spec.form = props.compactMap { name, prop in
                    let p = resolve(prop) ?? [:]
                    if J.str(p["format"]) == "binary" { return nil }
                    return KeyValue(key: name, value: J.text(sample(prop, depth: 1, stack: [])))
                }
            }
        } else if lower.contains("json") {
            spec.bodyKind = .json
            let value = example ?? sample(media["schema"], depth: 0, stack: [])
            spec.body = (value as? String).map(J.prettyBody) ?? J.serialize(value)
            if lower != "application/json" { spec.headers.append(KeyValue(key: "Content-Type", value: chosen)) }
        } else {
            spec.bodyKind = .text
            if let s = example.flatMap(J.str) { spec.body = s }
            else if let example { spec.body = J.serialize(example) }
            spec.headers.append(KeyValue(key: "Content-Type", value: chosen))
        }
        var hint = "`\(chosen)` — \(typeName(media["schema"] as? J.Dict))"
        if J.bool(rb["required"]) { hint += " (required)" }
        if let d = J.str(rb["description"]), !d.isEmpty { hint += "\n\n" + d }
        return hint
    }

    /// Properties of an object schema, merging allOf.
    func mergedProperties(_ schemaRef: Any?, depth: Int = 0) -> [(String, Any)] {
        guard depth < 8, let s = resolve(schemaRef) else { return [] }
        var out: [(String, Any)] = []
        for sub in (s["allOf"] as? [Any]) ?? [] { out += mergedProperties(sub, depth: depth + 1) }
        if let first = ((s["oneOf"] ?? s["anyOf"]) as? [Any])?.first { out += mergedProperties(first, depth: depth + 1) }
        if let props = s["properties"] as? J.Dict {
            for k in YAML.keys(props) { out.removeAll { $0.0 == k }; out.append((k, props[k]!)) }
        }
        return out
    }

    // MARK: Example generation

    /// Builds a sample value from a schema. `stack` holds $ref names currently being expanded (recursion guard).
    func sample(_ schemaRef: Any?, depth: Int, stack: Set<String>, forRequest: Bool = true) -> Any {
        guard var s = schemaRef as? J.Dict else { return NSNull() }
        var stack = stack
        var hops = 0
        while let ref = J.str(s["$ref"]), hops < 32 {
            if stack.contains(ref) { return J.ordered([]) }
            stack.insert(ref)
            guard let target = lookup(ref) as? J.Dict else { return J.ordered([]) }
            s = target
            hops += 1
        }
        if let ex = s["example"] { return ex }
        if let ex = (s["examples"] as? [Any])?.first { return ex }
        if let c = s["const"] { return c }
        if let d = s["default"] { return d }
        if let e = (s["enum"] as? [Any])?.first { return e }
        if depth > 6 { return NSNull() }

        if let all = s["allOf"] as? [Any] {
            var pairs: [(String, Any)] = []
            var nonObject: Any?
            for sub in all {
                let v = sample(sub, depth: depth + 1, stack: stack, forRequest: forRequest)
                if let d = v as? J.Dict {
                    for k in YAML.keys(d) { pairs.removeAll { $0.0 == k }; pairs.append((k, d[k]!)) }
                } else if !(v is NSNull) {
                    nonObject = v
                }
            }
            if let own = s["properties"] as? J.Dict {
                for k in YAML.keys(own) {
                    pairs.removeAll { $0.0 == k }
                    pairs.append((k, sample(own[k], depth: depth + 1, stack: stack, forRequest: forRequest)))
                }
            }
            if pairs.isEmpty, let nonObject { return nonObject }
            return J.ordered(pairs)
        }
        if let first = ((s["oneOf"] ?? s["anyOf"]) as? [Any])?.first {
            return sample(first, depth: depth + 1, stack: stack, forRequest: forRequest)
        }

        var type = J.str(s["type"])
        if type == nil, let types = s["type"] as? [Any] {
            type = types.compactMap(J.str).first { $0 != "null" }
        }
        if type == nil { type = s["properties"] != nil ? "object" : s["items"] != nil ? "array" : nil }

        switch type {
        case "object":
            var pairs: [(String, Any)] = []
            if let props = s["properties"] as? J.Dict {
                for k in YAML.keys(props) {
                    let p = resolve(props[k]) ?? [:]
                    if forRequest, J.bool(p["readOnly"]) { continue }
                    pairs.append((k, sample(props[k], depth: depth + 1, stack: stack, forRequest: forRequest)))
                }
            } else if let ap = s["additionalProperties"] as? J.Dict {
                pairs.append(("key", sample(ap, depth: depth + 1, stack: stack, forRequest: forRequest)))
            }
            return J.ordered(pairs)
        case "array":
            let item = sample(s["items"], depth: depth + 1, stack: stack, forRequest: forRequest)
            return item is NSNull && s["items"] == nil ? [Any]() : [item]
        case "integer":
            return NSNumber(value: (s["minimum"] as? NSNumber)?.intValue ?? 0)
        case "number":
            return (s["minimum"] as? NSNumber) ?? NSNumber(value: 0)
        case "boolean":
            return true
        case "string":
            return stringSample(s)
        case "null":
            return NSNull()
        default:
            return s.isEmpty ? NSNull() : J.ordered([])
        }
    }

    func stringSample(_ s: J.Dict) -> String {
        switch J.str(s["format"])?.lowercased() ?? "" {
        case "date-time": return "2024-01-01T12:00:00Z"
        case "date": return "2024-01-01"
        case "time": return "12:00:00"
        case "email": return "user@example.com"
        case "uuid": return "3fa85f64-5717-4562-b3fc-2c963f66afa6"
        case "uri", "url": return "https://example.com"
        case "hostname": return "example.com"
        case "ipv4": return "192.168.0.1"
        case "ipv6": return "::1"
        case "byte": return "U3dhZ2dlcg=="
        case "password": return "password"
        case "binary": return ""
        default: return "string"
        }
    }

    func typeName(_ schemaRef: J.Dict?) -> String {
        guard let raw = schemaRef, !raw.isEmpty else { return "" }
        if let n = Self.refName(raw) { return "`\(n)`" }
        guard let s = resolve(raw) else { return "" }
        if let t = J.str(s["type"]) {
            if t == "array" {
                let inner = typeName(s["items"] as? J.Dict)
                return inner.isEmpty ? "`array`" : "array of \(inner)"
            }
            if let f = J.str(s["format"]) { return "`\(t) (\(f))`" }
            return "`\(t)`"
        }
        if let all = s["allOf"] as? [Any] { return all.compactMap { typeName($0 as? J.Dict) }.filter { !$0.isEmpty }.joined(separator: " & ") }
        if let any = (s["oneOf"] ?? s["anyOf"]) as? [Any] { return any.compactMap { typeName($0 as? J.Dict) }.filter { !$0.isEmpty }.joined(separator: " | ") }
        if s["properties"] != nil { return "`object`" }
        return ""
    }

    // MARK: Security

    mutating func applySecurity(op: J.Dict, to spec: inout RequestSpec) {
        guard let reqs = (op["security"] ?? root["security"]) as? [Any] else { return }
        let schemes: J.Dict = isV2 ? (root["securityDefinitions"] as? J.Dict ?? [:])
            : ((root["components"] as? J.Dict)?["securitySchemes"] as? J.Dict ?? [:])
        for case let req as J.Dict in reqs {
            for name in YAML.keys(req) {
                guard let scheme = resolve(schemes[name]) else { continue }
                let scopes = ((req[name] as? [Any]) ?? []).compactMap(J.str).joined(separator: " ")
                if let auth = makeAuth(scheme, scopes: scopes) { spec.auth = auth; return }
            }
        }
    }

    mutating func makeAuth(_ s: J.Dict, scopes: String) -> Auth? {
        let type = (J.str(s["type"]) ?? "").lowercased()
        var auth = Auth()
        switch type {
        case "http", "basic":
            let scheme = type == "basic" ? "basic" : (J.str(s["scheme"]) ?? "").lowercased()
            if scheme == "basic" {
                auth.kind = .basic
                auth.username = "{{username}}"; auth.password = "{{password}}"
                vars.add("username"); vars.add("password")
            } else if scheme == "bearer" {
                auth.kind = .bearer
                auth.token = "{{token}}"
                vars.add("token")
            } else {
                return nil
            }
        case "apikey":
            auth.kind = .apiKey
            let loc = (J.str(s["in"]) ?? "header").lowercased()
            auth.apiKeyIn = loc == "query" ? .query : .header
            auth.apiKeyName = loc == "cookie" ? "Cookie" : (J.str(s["name"]) ?? "X-API-Key")
            auth.apiKeyValue = loc == "cookie" ? "\(J.str(s["name"]) ?? "apiKey")={{apiKey}}" : "{{apiKey}}"
            vars.add("apiKey")
        case "oauth2":
            var cfg = OAuthConfig()
            if isV2 {
                switch (J.str(s["flow"]) ?? "").lowercased() {
                case "application": cfg.grant = .clientCredentials
                case "password": cfg.grant = .password
                default: cfg.grant = .authorizationCode
                }
                cfg.authURL = J.str(s["authorizationUrl"]) ?? ""
                cfg.tokenURL = J.str(s["tokenUrl"]) ?? ""
            } else {
                let flows = s["flows"] as? J.Dict ?? [:]
                let pick: [(String, OAuthGrant)] = [("authorizationCode", .authorizationCode), ("clientCredentials", .clientCredentials),
                                                    ("password", .password), ("implicit", .authorizationCode)]
                for (key, grant) in pick {
                    if let f = flows[key] as? J.Dict {
                        cfg.grant = grant
                        cfg.authURL = J.str(f["authorizationUrl"]) ?? ""
                        cfg.tokenURL = J.str(f["tokenUrl"]) ?? ""
                        break
                    }
                }
            }
            // Implicit-only flows have no token endpoint — Wisp can't use them, so don't wire up a dead OAuth config.
            guard !cfg.tokenURL.isEmpty else { return nil }
            cfg.scope = scopes
            cfg.clientID = "{{clientId}}"
            cfg.clientSecret = "{{clientSecret}}"
            vars.add("clientId"); vars.add("clientSecret")
            if cfg.grant == .password {
                cfg.username = "{{username}}"; cfg.password = "{{password}}"
                vars.add("username"); vars.add("password")
            }
            auth.kind = .oauth2
            auth.oauth = cfg
        default:
            return nil
        }
        return auth
    }

    // MARK: Docs

    func docs(spec: RequestSpec, path: String, method m: String, summary: String, op: J.Dict,
              params: [Param], bodyHint: String) -> String {
        func cell(_ s: String) -> String {
            s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        var md = "# \(summary.isEmpty ? spec.name : summary)\n\n`\(m) \(path)`"
        if J.bool(op["deprecated"]) { md += "\n\n> **Deprecated**" }
        if let d = J.str(op["description"])?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { md += "\n\n" + d }
        let shown = params.filter { $0.location != "body" }
        if !shown.isEmpty {
            md += "\n\n## Parameters\n\n| Name | In | Required | Type | Description |\n| --- | --- | --- | --- | --- |"
            for p in shown {
                let t = typeName(p.schema).replacingOccurrences(of: "`", with: "")
                md += "\n| `\(cell(p.name))` | \(p.location) | \(p.required ? "yes" : "no") | \(cell(t)) | \(cell(p.description)) |"
            }
        }
        if !bodyHint.isEmpty { md += "\n\n## Request body\n\n" + bodyHint }
        if let responses = op["responses"] as? J.Dict, !YAML.keys(responses).isEmpty {
            md += "\n\n## Responses\n"
            for code in YAML.keys(responses) {
                let r = resolve(responses[code]) ?? [:]
                let desc = (J.str(r["description"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                md += "\n- `\(code)`" + (desc.isEmpty ? "" : " — " + cell(desc))
            }
        }
        return md + "\n"
    }
}

// MARK: - Postman v2.0 / v2.1

private struct PostmanImporter {
    let root: J.Dict
    var vars = VarBag()

    mutating func run() -> ImportResult {
        let info = root["info"] as? J.Dict ?? [:]
        let name = J.str(info["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? "Postman Collection"
        let schema = J.str(info["schema"]) ?? ""
        let format = schema.contains("v2.0") ? "Postman v2.0" : "Postman v2.1"
        for v in J.dicts(root["variable"]) {
            guard let k = J.str(v["key"] ?? v["id"]) else { continue }
            vars.add(k, J.text(v["value"]))
        }
        var out: [RequestSpec] = []
        walk(J.dicts(root["item"]), folder: name, auth: root["auth"] as? J.Dict, into: &out)
        return ImportResult(name: name, requests: out, variables: vars.items, format: format)
    }

    mutating func walk(_ items: [J.Dict], folder: String, auth: J.Dict?, into out: inout [RequestSpec]) {
        for item in items {
            let itemName = J.str(item["name"]) ?? ""
            let inherited = Self.effectiveAuth(item["auth"] as? J.Dict, parent: auth)
            if let children = item["item"] as? [Any] {
                let sub = itemName.isEmpty ? folder : "\(folder)/\(itemName)"
                walk(children.compactMap { $0 as? J.Dict }, folder: sub, auth: inherited, into: &out)
            } else if item["request"] != nil {
                out.append(request(item, folder: folder, parentAuth: auth))
            }
        }
    }

    /// `nil`/"inherit" auth defers to the parent.
    static func effectiveAuth(_ a: J.Dict?, parent: J.Dict?) -> J.Dict? {
        guard let a, let t = J.str(a["type"]), t != "inherit" else { return parent }
        return a
    }

    static func description(_ v: Any?) -> String {
        if let s = J.str(v) { return s }
        if let d = v as? J.Dict { return J.str(d["content"]) ?? "" }
        return ""
    }

    mutating func request(_ item: J.Dict, folder: String, parentAuth: J.Dict?) -> RequestSpec {
        var spec = RequestSpec()
        spec.folder = folder
        let r: J.Dict
        if let s = J.str(item["request"]) { r = ["url": s] } else { r = item["request"] as? J.Dict ?? [:] }
        spec.method = method(J.str(r["method"]))

        // URL
        var url = ""
        if let s = J.str(r["url"]) {
            url = s
        } else if let u = r["url"] as? J.Dict {
            if let raw = J.str(u["raw"]) {
                url = raw
            } else {
                let host = (u["host"] as? [Any])?.compactMap(J.str).joined(separator: ".") ?? J.str(u["host"]) ?? ""
                let path = (u["path"] as? [Any])?.compactMap(J.str).joined(separator: "/") ?? J.str(u["path"]) ?? ""
                url = (J.str(u["protocol"]).map { $0 + "://" } ?? "") + host + (path.isEmpty ? "" : "/" + path)
                let q = J.dicts(u["query"]).filter { !J.bool($0["disabled"]) }
                    .map { "\(J.str($0["key"]) ?? "")=\(J.str($0["value"]) ?? "")" }
                if !q.isEmpty { url += "?" + q.joined(separator: "&") }
            }
            for v in J.dicts(u["variable"]) {
                if let k = J.str(v["key"]) { vars.add(k, J.text(v["value"])) }
            }
        }
        spec.url = colonParamsToVars(url.trimmingCharacters(in: .whitespacesAndNewlines))
        spec.name = J.str(item["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? spec.suggestedName

        // Headers
        if let hs = J.str(r["header"]) {
            for line in hs.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                spec.headers.append(KeyValue(key: parts[0].trimmingCharacters(in: .whitespaces),
                                             value: parts[1].trimmingCharacters(in: .whitespaces)))
            }
        } else {
            for h in J.dicts(r["header"]) {
                guard let k = J.str(h["key"]) else { continue }
                spec.headers.append(KeyValue(enabled: !J.bool(h["disabled"]), key: k, value: J.str(h["value"]) ?? ""))
            }
        }

        // Body
        if let body = r["body"] as? J.Dict, !J.bool(body["disabled"]) {
            switch J.str(body["mode"]) ?? "" {
            case "raw":
                let raw = J.str(body["raw"]) ?? ""
                let lang = J.str(((body["options"] as? J.Dict)?["raw"] as? J.Dict)?["language"])?.lowercased()
                let ct = spec.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
                if lang == "json" || ct.contains("json") || (lang == nil && J.looksLikeJSON(raw)) {
                    spec.bodyKind = .json
                    spec.body = J.prettyBody(raw)
                } else if !raw.isEmpty {
                    spec.bodyKind = .text
                    spec.body = raw
                }
            case "urlencoded", "formdata":
                spec.bodyKind = .form
                spec.form = J.dicts(body[J.str(body["mode"])!]).compactMap { f in
                    guard let k = J.str(f["key"]), (J.str(f["type"]) ?? "text") == "text" else { return nil }
                    return KeyValue(enabled: !J.bool(f["disabled"]), key: k, value: J.str(f["value"]) ?? "")
                }
                if J.str(body["mode"]) == "urlencoded" {
                    spec.headers.removeAll { $0.key.lowercased() == "content-type" && $0.value.lowercased().contains("x-www-form-urlencoded") }
                }
            case "graphql":
                let g = body["graphql"] as? J.Dict ?? [:]
                let q = J.str(g["query"]) ?? ""
                let rawVars = J.str(g["variables"]) ?? ""
                let parsedVars = rawVars.isEmpty ? nil : (try? YAML.parse(rawVars, keepOrder: true)) as? J.Dict
                spec.bodyKind = .json
                spec.body = J.serialize(J.ordered([("query", q), ("variables", parsedVars ?? J.ordered([]))]))
            default:
                break
            }
        }

        // Auth: request-level, else inherited from folders/collection.
        let auth = Self.effectiveAuth(r["auth"] as? J.Dict, parent: Self.effectiveAuth(item["auth"] as? J.Dict, parent: parentAuth))
        if let auth { spec.auth = Self.auth(auth) }

        let desc = [Self.description(item["description"]), Self.description(r["description"])]
            .filter { !$0.isEmpty }
        spec.docs = desc.isEmpty ? "" : "# \(spec.name)\n\n" + desc.joined(separator: "\n\n") + "\n"
        return spec
    }

    /// Reads `auth[type]` attributes, either v2.1 `[{key, value}]` arrays or v2.0 objects.
    static func attrs(_ auth: J.Dict, _ type: String) -> [String: String] {
        var out: [String: String] = [:]
        if let list = auth[type] as? [Any] {
            for case let a as J.Dict in list { if let k = J.str(a["key"]) { out[k] = J.text(a["value"]) } }
        } else if let d = auth[type] as? J.Dict {
            for k in YAML.keys(d) { out[k] = J.text(d[k]) }
        }
        return out
    }

    static func auth(_ a: J.Dict) -> Auth {
        let type = (J.str(a["type"]) ?? "").lowercased()
        let at = attrs(a, type)
        var auth = Auth()
        switch type {
        case "bearer":
            auth.kind = .bearer
            auth.token = at["token"] ?? ""
        case "basic":
            auth.kind = .basic
            auth.username = at["username"] ?? ""
            auth.password = at["password"] ?? ""
        case "apikey":
            auth.kind = .apiKey
            auth.apiKeyName = at["key"] ?? "X-API-Key"
            auth.apiKeyValue = at["value"] ?? ""
            auth.apiKeyIn = (at["in"] ?? "header").lowercased() == "query" ? .query : .header
        case "oauth2":
            let tokenURL = at["accessTokenUrl"] ?? at["tokenUrl"] ?? ""
            if tokenURL.isEmpty, let tok = at["accessToken"], !tok.isEmpty {
                auth.kind = .bearer
                auth.token = tok
                break
            }
            var cfg = OAuthConfig()
            switch (at["grant_type"] ?? "authorization_code").lowercased() {
            case "client_credentials": cfg.grant = .clientCredentials
            case "password", "password_credentials": cfg.grant = .password
            default: cfg.grant = .authorizationCode
            }
            cfg.authURL = at["authUrl"] ?? ""
            cfg.tokenURL = tokenURL
            cfg.clientID = at["clientId"] ?? ""
            cfg.clientSecret = at["clientSecret"] ?? ""
            cfg.scope = at["scope"] ?? ""
            cfg.audience = at["audience"] ?? ""
            cfg.username = at["username"] ?? ""
            cfg.password = at["password"] ?? ""
            if let redirect = at["redirect_uri"], !redirect.isEmpty { cfg.redirectURI = redirect }
            cfg.clientAuthInBody = (at["client_authentication"] ?? "").lowercased() == "body"
            auth.kind = .oauth2
            auth.oauth = cfg
        default:
            break
        }
        return auth
    }
}

// MARK: - Insomnia v4

private struct InsomniaImporter {
    let root: J.Dict

    static func fixVars(_ s: String) -> String {
        regexReplace(s, #"\{\{\s*_\.([A-Za-z0-9_.\-]+)\s*\}\}"#, "{{$1}}")
    }

    func run() -> ImportResult {
        let resources = J.dicts(root["resources"])
        let byID = Dictionary(resources.compactMap { r in J.str(r["_id"]).map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let workspace = resources.first { J.str($0["_type"]) == "workspace" }
        let name = J.str(workspace?["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? "Insomnia"

        // Environments: base (parent is the workspace) first, sub-environments override.
        var vars = VarBag()
        let envs = resources.filter { J.str($0["_type"]) == "environment" }
        let ordered = envs.filter { J.str($0["parentId"])?.hasPrefix("wrk") == true } + envs.filter { J.str($0["parentId"])?.hasPrefix("wrk") != true }
        var values: [(String, String)] = []
        func flatten(_ d: J.Dict, prefix: String) {
            for k in YAML.keys(d) {
                let key = prefix.isEmpty ? k : "\(prefix).\(k)"
                if let sub = d[k] as? J.Dict { flatten(sub, prefix: key) }
                else {
                    let v = Self.fixVars(J.text(d[k]))
                    if let i = values.firstIndex(where: { $0.0 == key }) { if !v.isEmpty { values[i].1 = v } }
                    else { values.append((key, v)) }
                }
            }
        }
        for env in ordered { flatten(env["data"] as? J.Dict ?? [:], prefix: "") }
        for (k, v) in values { vars.add(k, v) }

        func folderPath(_ parentID: String?) -> String {
            var parts: [String] = []
            var cur = parentID
            var guardCount = 0
            while let id = cur, let r = byID[id], J.str(r["_type"]) == "request_group", guardCount < 64 {
                parts.insert(J.str(r["name"]) ?? "", at: 0)
                cur = J.str(r["parentId"])
                guardCount += 1
            }
            return ([name] + parts.filter { !$0.isEmpty }).joined(separator: "/")
        }

        var out: [RequestSpec] = []
        for r in resources where J.str(r["_type"]) == "request" {
            var spec = RequestSpec()
            spec.folder = folderPath(J.str(r["parentId"]))
            spec.method = method(J.str(r["method"]))
            spec.url = Self.fixVars(J.str(r["url"]) ?? "")
            spec.name = J.str(r["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? spec.suggestedName
            spec.params = J.dicts(r["parameters"]).map {
                KeyValue(enabled: !J.bool($0["disabled"]), key: Self.fixVars(J.str($0["name"]) ?? ""), value: Self.fixVars(J.str($0["value"]) ?? ""))
            }
            spec.headers = J.dicts(r["headers"]).map {
                KeyValue(enabled: !J.bool($0["disabled"]), key: Self.fixVars(J.str($0["name"]) ?? ""), value: Self.fixVars(J.str($0["value"]) ?? ""))
            }
            if let body = r["body"] as? J.Dict {
                let mime = (J.str(body["mimeType"]) ?? "").lowercased()
                let text = Self.fixVars(J.str(body["text"]) ?? "")
                if mime.contains("x-www-form-urlencoded") || mime.contains("multipart/form-data") {
                    spec.bodyKind = .form
                    spec.form = J.dicts(body["params"]).compactMap { p in
                        if J.str(p["type"]) == "file" { return nil }
                        return KeyValue(enabled: !J.bool(p["disabled"]), key: Self.fixVars(J.str(p["name"]) ?? ""), value: Self.fixVars(J.str(p["value"]) ?? ""))
                    }
                    spec.headers.removeAll { $0.key.lowercased() == "content-type" && mime.contains("x-www-form-urlencoded") }
                } else if mime.contains("json") || mime.contains("graphql") || (!text.isEmpty && mime.isEmpty && J.looksLikeJSON(text)) {
                    spec.bodyKind = .json
                    spec.body = J.prettyBody(text)
                } else if !text.isEmpty {
                    spec.bodyKind = .text
                    spec.body = text
                }
            }
            if let a = r["authentication"] as? J.Dict, !J.bool(a["disabled"]) {
                spec.auth = Self.auth(a)
            }
            if let d = J.str(r["description"]), !d.isEmpty { spec.docs = "# \(spec.name)\n\n\(d)\n" }
            out.append(spec)
        }
        return ImportResult(name: name, requests: out, variables: vars.items, format: "Insomnia")
    }

    static func auth(_ a: J.Dict) -> Auth {
        func s(_ k: String) -> String { fixVars(J.str(a[k]) ?? "") }
        var auth = Auth()
        switch (J.str(a["type"]) ?? "").lowercased() {
        case "bearer":
            auth.kind = .bearer
            auth.token = s("token")
        case "basic":
            auth.kind = .basic
            auth.username = s("username")
            auth.password = s("password")
        case "apikey":
            auth.kind = .apiKey
            auth.apiKeyName = s("key").isEmpty ? "X-API-Key" : s("key")
            auth.apiKeyValue = s("value")
            auth.apiKeyIn = s("addTo").lowercased().contains("query") ? .query : .header
        case "oauth2":
            var cfg = OAuthConfig()
            switch s("grantType").lowercased() {
            case "client_credentials": cfg.grant = .clientCredentials
            case "password": cfg.grant = .password
            default: cfg.grant = .authorizationCode
            }
            cfg.authURL = s("authorizationUrl")
            cfg.tokenURL = s("accessTokenUrl")
            cfg.clientID = s("clientId")
            cfg.clientSecret = s("clientSecret")
            cfg.scope = s("scope")
            cfg.audience = s("audience")
            cfg.username = s("username")
            cfg.password = s("password")
            if !s("redirectUrl").isEmpty { cfg.redirectURI = s("redirectUrl") }
            auth.kind = .oauth2
            auth.oauth = cfg
        default:
            break
        }
        return auth
    }
}

// MARK: - HAR

private struct HARImporter {
    let log: J.Dict

    static let staticExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "avif",
                                                "css", "js", "mjs", "map", "woff", "woff2", "ttf", "otf", "eot",
                                                "mp4", "webm", "mp3", "wav"]
    static let skippedHeaders: Set<String> = ["cookie", "content-length", "host", "connection", "accept-encoding"]

    func run() -> ImportResult {
        var out: [RequestSpec] = []
        var seen = Set<String>()
        for entry in J.dicts(log["entries"]) {
            guard let r = entry["request"] as? J.Dict, let url = J.str(r["url"]), url.hasPrefix("http") else { continue }
            let comps = URLComponents(string: url)
            let ext = ((comps?.path ?? "") as NSString).pathExtension.lowercased()
            if Self.staticExtensions.contains(ext) { continue }
            let mime = (J.str(((entry["response"] as? J.Dict)?["content"] as? J.Dict)?["mimeType"]) ?? "").lowercased()
            if mime.hasPrefix("image/") || mime.hasPrefix("font/") || mime.contains("css") || mime.contains("javascript") { continue }

            var spec = RequestSpec()
            spec.method = method(J.str(r["method"]))
            spec.url = url
            spec.folder = comps?.host ?? "HAR"
            spec.name = spec.suggestedName
            spec.headers = J.dicts(r["headers"]).compactMap { h in
                guard let k = J.str(h["name"]), !k.hasPrefix(":"), !Self.skippedHeaders.contains(k.lowercased()) else { return nil }
                return KeyValue(key: k, value: J.str(h["value"]) ?? "")
            }
            if let post = r["postData"] as? J.Dict {
                let pm = (J.str(post["mimeType"]) ?? "").lowercased()
                let text = J.str(post["text"]) ?? ""
                let params = J.dicts(post["params"])
                if pm.contains("json") || (!pm.contains("form") && J.looksLikeJSON(text)) {
                    spec.bodyKind = .json
                    spec.body = J.prettyBody(text)
                } else if pm.contains("x-www-form-urlencoded") || pm.contains("multipart/form-data") {
                    spec.bodyKind = .form
                    if !params.isEmpty {
                        spec.form = params.compactMap { p in
                            guard p["fileName"] == nil, let k = J.str(p["name"]) else { return nil }
                            return KeyValue(key: k, value: J.str(p["value"]) ?? "")
                        }
                    } else {
                        spec.form = text.split(separator: "&").map { pair in
                            let kv = pair.split(separator: "=", maxSplits: 1).map {
                                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
                            }
                            return KeyValue(key: kv.first ?? "", value: kv.count > 1 ? kv[1] : "")
                        }
                    }
                    spec.headers.removeAll { $0.key.lowercased() == "content-type" }
                } else if !text.isEmpty {
                    spec.bodyKind = .text
                    spec.body = text
                }
            }
            let key = "\(spec.method.rawValue) \(spec.url) \(spec.body)"
            if seen.insert(key).inserted { out.append(spec) }
        }
        let title = J.str(J.dicts(log["pages"]).first?["title"]).flatMap { $0.isEmpty ? nil : $0 } ?? "HAR Import"
        return ImportResult(name: title, requests: out, variables: [], format: "HAR")
    }
}

// MARK: - cURL

private enum CurlImporter {
    static func isCurlLine(_ line: Substring) -> Bool {
        let t = line.drop { $0 == " " || $0 == "\t" }
        let s = t.hasPrefix("$ ") ? t.dropFirst(2) : t
        return s.hasPrefix("curl ") || s.hasPrefix("curl\t") || s == "curl"
    }

    static func looksLikeCurl(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains(where: isCurlLine)
    }

    static func parse(_ text: String) throws -> ImportResult {
        var chunks: [String] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if isCurlLine(line) {
                let t = line.drop { $0 == " " || $0 == "\t" }
                chunks.append(String(t.hasPrefix("$ ") ? t.dropFirst(2) : t))
            } else if !chunks.isEmpty {
                chunks[chunks.count - 1] += "\n" + line
            }
        }
        var out: [RequestSpec] = []
        for chunk in chunks {
            guard var spec = Curl.parse(chunk) else { continue }
            spec.name = spec.suggestedName
            spec.folder = hostOf(spec.url).isEmpty ? "cURL" : hostOf(spec.url)
            out.append(spec)
        }
        guard !out.isEmpty else { throw ImportError.invalid("No valid curl commands found.") }
        return ImportResult(name: out.count == 1 ? out[0].name : "cURL Import", requests: out, variables: [], format: "cURL")
    }
}
