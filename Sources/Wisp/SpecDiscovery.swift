import Foundation

/// Finds the machine-readable OpenAPI/Swagger spec behind an API docs URL. Pure logic: fetches pages,
/// scans HTML for known doc-renderer hints, then probes well-known paths. Never executes JS.
enum SpecDiscovery {
    struct Found {
        var data: Data          // the spec bytes (JSON or YAML) — or any importable document the URL served
        var specURL: URL        // where it was found
        var via: String         // human-readable source, e.g. "Redoc spec-url", "well-known path /openapi.json"
        var result: ImportResult // already parsed with Importer.parse
    }

    enum Failure: LocalizedError {
        case notFound(page: URL, tried: Int)
        case unreachable(URL, String)

        var errorDescription: String? {
            switch self {
            case let .notFound(page, tried):
                return "No OpenAPI/Swagger spec found on \(page.host ?? page.absoluteString) (checked \(tried) places). "
                    + "Paste the spec's URL (often …/openapi.json) or import the file."
            case let .unreachable(url, msg):
                return "Couldn't reach \(url.absoluteString): \(msg)"
            }
        }
    }

    typealias Fetch = (URL) async throws -> (Data, URLResponse)

    static let maxBytes = 25 * 1024 * 1024
    static let maxProbes = 16
    static let wellKnown = ["openapi.json", "openapi.yaml", "swagger.json", "v3/api-docs", "api-docs", "api/openapi.json",
                            "swagger/v1/swagger.json", ".well-known/openapi.json", "docs/openapi.json", "docs/api-docs.json",
                            "docs.openapi", "openapi.yml"]

    static func discover(_ url: URL, fetch: Fetch? = nil) async throws -> Found {
        let get: Fetch = fetch ?? { try await defaultFetch($0, timeout: 15) }
        let probeFetch: Fetch = fetch ?? { try await defaultFetch($0, timeout: 8) }
        var seen: Set<String> = [url.absoluteString]
        var tried = 1

        let page: Data, resp: URLResponse
        do { (page, resp) = try await get(url) } catch { throw Failure.unreachable(url, error.localizedDescription) }
        let base = resp.url ?? url
        seen.insert(base.absoluteString)
        let pageOK = isOK(resp) && page.count <= maxBytes

        if pageOK, !isHTML(page, resp), let r = importable(page, strict: false) {
            return Found(data: page, specURL: base, via: "the URL itself", result: r)
        }

        // Fetches each URL at most once; nil for errors, non-2xx and oversized bodies.
        func load(_ u: URL) async -> (Data, URLResponse)? {
            guard seen.insert(u.absoluteString).inserted else { return nil }
            tried += 1
            guard let pair = try? await get(u), isOK(pair.1), pair.0.count <= maxBytes else { return nil }
            return pair
        }
        func attempt(_ list: [(URL, String)]) async -> Found? {
            for (u, via) in list {
                if let p = await load(u), let f = spec(p.0, p.1, u, via) { return f }
            }
            return nil
        }

        if pageOK, isHTML(page, resp), let html = text(page) {
            let docBase = baseURL(html, page: base)
            if let f = await attempt(rendererCandidates(html, base: docBase)) { return f }

            // Swagger UI: inline init, initializer scripts (max 2), then configUrl JSON.
            var sw: (urls: [URL], configs: [URL]) = html.range(of: "SwaggerUIBundle").map { swaggerURLs(String(html[$0.lowerBound...]), base: docBase) } ?? ([], [])
            var loose: [URL] = []
            for s in initializerScripts(html, base: docBase).prefix(2) {
                if let p = await load(s), let js = text(p.0) {
                    let more = swaggerURLs(js, base: s)
                    sw.urls += more.urls; sw.configs += more.configs
                    loose += specLiterals(js, base: s)
                }
            }
            if let f = await attempt(sw.urls.map { ($0, "Swagger UI config") }) { return f }
            for c in sw.configs {
                guard let p = await load(c), let obj = try? JSONSerialization.jsonObject(with: p.0) as? [String: Any] else { continue }
                let raw = obj["url"] as? String ?? ((obj["urls"] as? [[String: Any]])?.first?["url"] as? String)
                if let raw, let u = resolve(raw, base: c), let f = await attempt([(u, "Swagger UI configUrl")]) { return f }
            }
            // `url: someVariable` — fall back to spec-looking literals in the script, same host first.
            let sameHost = loose.filter { $0.host == base.host }, other = loose.filter { $0.host != base.host }
            if let f = await attempt((sameHost + other).map { ($0, "Swagger UI config") }) { return f }

            if let f = await attempt(linkCandidates(html, base: docBase)) { return f }
        }

        // Well-known paths, ≤4 in flight, first hit in priority order wins.
        let probes = probeURLs(for: base).filter { !seen.contains($0.absoluteString) }
        var i = 0
        while i < probes.count {
            let batch = Array(probes[i..<min(i + 4, probes.count)])
            i += batch.count
            tried += batch.count
            let hits = await withTaskGroup(of: (Int, Found?).self) { group -> [Int: Found] in
                for (k, u) in batch.enumerated() {
                    group.addTask {
                        guard let p = try? await probeFetch(u), isOK(p.1), p.0.count <= maxBytes else { return (k, nil) }
                        return (k, spec(p.0, p.1, u, "well-known path \(u.path)"))
                    }
                }
                var out: [Int: Found] = [:]
                for await (k, f) in group { if let f { out[k] = f } }
                return out
            }
            if let k = hits.keys.min(), let f = hits[k] { return f }
        }
        throw Failure.notFound(page: base, tried: tried)
    }

    // MARK: - Fetch & classify

    static func defaultFetch(_ url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("application/json, application/yaml, text/yaml, text/html;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        return try await HTTPClient.session.data(for: req)
    }

    static func isOK(_ r: URLResponse) -> Bool {
        guard let h = r as? HTTPURLResponse else { return true }
        return (200..<300).contains(h.statusCode)
    }

    static func isHTML(_ d: Data, _ r: URLResponse) -> Bool {
        if let ct = (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? r.mimeType, ct.lowercased().contains("html") { return true }
        var bytes = d.prefix(512)[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return bytes.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == UInt8(ascii: "<")
    }

    /// Accepts OpenAPI/Swagger/Postman/Insomnia; `strict: false` (the pasted URL itself) also allows HAR. Never cURL.
    static func importable(_ d: Data, strict: Bool) -> ImportResult? {
        guard let r = try? Importer.parse(d), r.format != "cURL", !(strict && r.format == "HAR") else { return nil }
        return r
    }

    static func spec(_ d: Data, _ r: URLResponse, _ u: URL, _ via: String) -> Found? {
        guard !isHTML(d, r), let res = importable(d, strict: true) else { return nil }
        return Found(data: d, specURL: r.url ?? u, via: via, result: res)
    }

    static func text(_ d: Data) -> String? { String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) }

    // MARK: - HTML scanning

    static func baseURL(_ html: String, page: URL) -> URL {
        guard let tag = tags("base", html).first, let href = attr("href", tag), let u = resolve(href, base: page) else { return page }
        return u
    }

    /// Doc renderers that name their spec explicitly: Redoc, RapiDoc, Stoplight Elements, openapi-explorer, Scalar.
    static func rendererCandidates(_ html: String, base: URL) -> [(URL, String)] {
        var out: [(String, String)] = []
        out += tags("redoc", html).compactMap { attr("spec-url", $0).map { ($0, "Redoc spec-url") } }
        out += captures(#"Redoc\.init\(\s*["']([^"']+)["']"#, html).map { ($0, "Redoc.init") }
        out += tags("rapi-doc", html).compactMap { attr("spec-url", $0).map { ($0, "RapiDoc spec-url") } }
        out += tags("elements-api", html).compactMap { attr("apiDescriptionUrl", $0).map { ($0, "Stoplight Elements apiDescriptionUrl") } }
        out += tags("openapi-explorer", html).compactMap { attr("spec-url", $0).map { ($0, "openapi-explorer spec-url") } }
        out += tags("script", html).filter { attr("id", $0) == "api-reference" }
            .compactMap { attr("data-url", $0).map { ($0, "Scalar data-url") } }
        return out.compactMap { raw, via in resolve(raw, base: base).map { ($0, via) } }
    }

    /// Swagger UI `url:` / `urls: [{url:}]` literals and `configUrl:` in JS (or the page from `SwaggerUIBundle` on).
    static func swaggerURLs(_ js: String, base: URL) -> (urls: [URL], configs: [URL]) {
        let urls = captures(#"(?<![\w$.\-])["']?url["']?\s*:\s*["'`]([^"'`\s]+)["'`]"#, js, ci: false)
        let configs = captures(#"["']?configUrl["']?\s*:\s*["'`]([^"'`\s]+)["'`]"#, js, ci: false)
        return (urls.compactMap { resolve($0, base: base) }, configs.compactMap { resolve($0, base: base) })
    }

    /// Any string-ish token in JS that looks like a spec file URL (used when `url:` is a variable).
    static func specLiterals(_ js: String, base: URL) -> [URL] {
        captures(#"((?:https?:)?[\w./:-]*(?:openapi|swagger|api-docs|spec)[^\s"'`,=/]*\.(?:json|ya?ml))(?![\w.])"#, js)
            .compactMap { resolve($0, base: base) }
    }

    static func initializerScripts(_ html: String, base: URL) -> [URL] {
        tags("script", html).compactMap { attr("src", $0) }.compactMap { resolve($0, base: base) }.filter { u in
            let name = u.lastPathComponent.lowercased()
            return u.host == base.host && u.scheme == base.scheme
                && ["swagger-initializer", "swagger-config", "swagger-ui-init"].contains { name.contains($0) }
        }
    }

    /// `<link rel=alternate type=application/openapi+…>` and any href/src that looks like a spec file.
    static func linkCandidates(_ html: String, base: URL) -> [(URL, String)] {
        var out: [(String, String)] = []
        for tag in tags("link", html) {
            guard (attr("rel", tag) ?? "").lowercased().contains("alternate"), let type = attr("type", tag)?.lowercased(),
                  type.hasPrefix("application/openapi+") || type.hasPrefix("application/vnd.oai.openapi"),
                  let href = attr("href", tag) else { continue }
            out.append((href, "a <link rel=alternate> on the page"))
        }
        let specFile = #"(openapi|swagger|api-docs|spec)[^/]*\.(json|ya?ml)(\?.*)?$"#
        out += captures(#"\b(?:href|src)\s*=\s*["']([^"']+)["']"#, html)
            .filter { decode($0).range(of: specFile, options: [.regularExpression, .caseInsensitive]) != nil }
            .map { ($0, "a link on the page") }
        return out.compactMap { raw, via in resolve(raw, base: base).map { ($0, via) } }
    }

    static func probeURLs(for page: URL) -> [URL] {
        guard var root = URLComponents(url: page, resolvingAgainstBaseURL: true) else { return [] }
        root.query = nil; root.fragment = nil; root.user = nil; root.password = nil
        var dirs = page.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if let last = dirs.last, last.contains(".") { dirs.removeLast() }
        // Up to two deepest sub-directories of the page, deepest first.
        let prefixes = (0..<dirs.count).reversed().prefix(2).map { "/" + dirs[...$0].joined(separator: "/") + "/" }
        var paths: [String] = []
        for name in ["openapi.json", "swagger.json", "openapi.yaml"] { paths += prefixes.map { $0 + name } + ["/" + name] }
        paths += wellKnown.map { "/" + $0 } + prefixes.map { $0 + "api-docs.json" }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.prefix(maxProbes).compactMap { p in
            var c = root; c.percentEncodedPath = p; return c.url
        }
    }

    // MARK: - Tiny HTML/regex helpers

    static func tags(_ name: String, _ html: String) -> [String] {
        captures("(<" + NSRegularExpression.escapedPattern(for: name) + #"\b[^>]*>)"#, html)
    }

    static func attr(_ name: String, _ tag: String) -> String? {
        let pat = #"\s"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        guard let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for g in 1...3 { if let r = Range(m.range(at: g), in: tag) { return decode(String(tag[r])) } }
        return nil
    }

    /// First capture group of every match.
    static func captures(_ pattern: String, _ s: String, ci: Bool = true) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : []) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
    }

    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&#x2F;", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Absolute http(s) URL, skipping Postman "Run in Postman"/documenter links (not importable).
    static func resolve(_ raw: String, base: URL) -> URL? {
        guard let u = URL(string: decode(raw), relativeTo: base)?.absoluteURL, ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host?.lowercased() else { return nil }
        if ["postman.com", "getpostman.com", "postman.co"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return nil }
        return u
    }
}
