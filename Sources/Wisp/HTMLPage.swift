import AppKit

/// What a human needs from an HTML response in an API client: what page is this, and why did I get it?
struct HTMLSummary {
    struct Link: Hashable { var title: String; var url: URL }

    var title: String?
    var description: String?
    var headings: [String] = []
    var text = ""
    var links: [Link] = []
    /// `<meta http-equiv="refresh" content="0;url=…">` target — HTML-level redirects URLSession doesn't follow.
    var metaRefresh: URL?
    var hasPasswordField = false

    static func parse(_ html: String, base: URL?) -> HTMLSummary {
        let doc = String(html.prefix(2_000_000))
        var s = HTMLSummary()
        s.title = first(#"<title[^>]*>(.*?)</title>"#, in: doc).map(clean)
        s.description = (first(#"<meta[^>]+(?:name|property)\s*=\s*["'](?:description|og:description)["'][^>]*content\s*=\s*["']([^"']*)"#, in: doc)
            ?? first(#"<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]*(?:name|property)\s*=\s*["'](?:description|og:description)["']"#, in: doc)).map(clean)
        if let refresh = first(#"<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]*content\s*=\s*["']\s*\d*\s*;?\s*url\s*=\s*['"]?([^'">\s]+)"#, in: doc) {
            s.metaRefresh = URL(string: decode(refresh), relativeTo: base)?.absoluteURL
        }
        s.hasPasswordField = doc.range(of: #"<input[^>]+type\s*=\s*["']?password"#, options: [.regularExpression, .caseInsensitive]) != nil

        let body = strip(#"<(script|style|noscript|svg|template)\b[^>]*>.*?</\1>|<!--.*?-->"#, from: doc)
        s.headings = Array(all(#"<h[1-3][^>]*>(.*?)</h[1-3]>"#, in: body).map(clean).filter { !$0.isEmpty }.prefix(8))

        var seen = Set<String>()
        for m in matches(#"<a\b[^>]*href\s*=\s*["']([^"'#][^"']*)["'][^>]*>(.*?)</a>"#, in: body) {
            guard let url = URL(string: decode(m[0]), relativeTo: base)?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https", seen.insert(url.absoluteString).inserted else { continue }
            let title = clean(m[1])
            s.links.append(Link(title: title.isEmpty ? url.absoluteString : title, url: url))
            if s.links.count == 12 { break }
        }

        // Readable text: block-level tags become line breaks, everything else is stripped.
        var text = body.replacingOccurrences(of: #"<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article|/header|/footer)\b[^>]*>"#,
                                             with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decode(text)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        s.text = String(lines.joined(separator: "\n").prefix(3_000))
        return s
    }

    // MARK: helpers

    private static func regex(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func matches(_ p: String, in s: String) -> [[String]] {
        let ns = s as NSString
        return regex(p).matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    private static func first(_ p: String, in s: String) -> String? { matches(p, in: s).first?.first }
    private static func all(_ p: String, in s: String) -> [String] { matches(p, in: s).compactMap(\.first) }

    private static func strip(_ p: String, from s: String) -> String {
        let ns = s as NSString
        return regex(p).stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
    }

    private static func clean(_ s: String) -> String {
        decode(s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                       "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&copy;": "©", "&rsquo;": "’", "&lsquo;": "‘",
                       "&rdquo;": "”", "&ldquo;": "“"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        let rx = regex(#"&#(x[0-9a-f]+|\d+);"#)
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in rx.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let code = ns.substring(with: m.range(at: 1))
            let value = code.hasPrefix("x") || code.hasPrefix("X") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            result += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Plain-language explanation of why an API request came back as a web page.
struct HTMLHint {
    var title: String
    var detail: String

    /// `knownBase`: the {{baseUrl}} of an environment for this host, if any (e.g. https://connect.mailerlite.com/api).
    static func make(for r: ResponseData, summary: HTMLSummary, knownBase: String?) -> HTMLHint {
        let apiTip = knownBase.map { " Your environment for this host uses \($0)." }
            ?? " APIs usually live under a path like /api or /v1, or on an api. subdomain."
        if let hop = r.redirects.first, let final = r.redirects.last?.to, hop.from.host != final.host {
            return HTMLHint(title: "Redirected to \(final.host ?? final.absoluteString)",
                            detail: "\(hop.from.host ?? "The server") answered \(hop.status) and sent you to a web page instead of API data.\(apiTip)")
        }
        if let target = summary.metaRefresh {
            // Same site → the path is the useful part; another site → its host.
            let place = target.host == r.url?.host ? (target.path(percentEncoded: false).isEmpty ? "/" : target.path(percentEncoded: false)) : (target.host ?? target.absoluteString)
            return HTMLHint(title: "This page redirects to \(place)",
                            detail: "It's an HTML redirect (meta refresh), not API data.\(apiTip)")
        }
        if r.status == 401 || r.status == 403 || summary.hasPasswordField {
            return HTMLHint(title: "Looks like a sign-in page",
                            detail: "The request probably isn't authenticated. Add credentials in the Auth tab, or check that the token is valid.")
        }
        if r.status >= 500 {
            return HTMLHint(title: "Server error page",
                            detail: "The server — or a proxy/gateway in front of it — returned an HTML error (\(r.status)). Try again, or check the service status.")
        }
        if r.status == 404 {
            return HTMLHint(title: "Page not found", detail: "Nothing lives at this path. Check the URL and API version.\(apiTip)")
        }
        return HTMLHint(title: "This is a web page, not API data", detail: apiTip.trimmingCharacters(in: .whitespaces))
    }
}

enum HTMLHighlight {
    private static let rxTag = try! NSRegularExpression(pattern: #"<[!/?]?[a-zA-Z][^>]*>"#)
    private static let rxName = try! NSRegularExpression(pattern: #"^<[!/?]?[a-zA-Z][\w:-]*"#)
    private static let rxAttr = try! NSRegularExpression(pattern: #"\s([a-zA-Z_:][-\w:.]*)\s*="#)
    private static let rxValue = try! NSRegularExpression(pattern: #"=\s*("[^"]*"|'[^']*')"#)
    private static let rxComment = try! NSRegularExpression(pattern: #"<!--.*?-->"#, options: .dotMatchesLineSeparators)

    static func highlight(_ storage: NSTextStorage) {
        let s = storage.string
        let full = NSRange(location: 0, length: (s as NSString).length)
        guard full.length <= 2_000_000 else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
        for tag in rxTag.matches(in: s, range: full) {
            let r = tag.range
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            if let name = rxName.firstMatch(in: s, range: r) {
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: name.range)
            }
            for a in rxAttr.matches(in: s, range: r) { storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: a.range(at: 1)) }
            for v in rxValue.matches(in: s, range: r) { storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: v.range(at: 1)) }
        }
        for c in rxComment.matches(in: s, range: full) { storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: c.range) }
        storage.endEditing()
    }
}
