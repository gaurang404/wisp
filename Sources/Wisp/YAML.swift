import Foundation

/// Minimal YAML → Foundation JSON-object parser, good enough for real-world OpenAPI/Swagger documents.
/// Produces `[String: Any]`, `[Any]`, `String`, `NSNumber`, `Bool` and `NSNull`. Only the first document is read.
/// Supports block/flow collections, quoted & plain scalars, literal/folded block scalars, comments,
/// simple anchors/aliases and `<<` merge keys. Tags are ignored; complex (`?`) keys are rejected.
enum YAML {
    struct ParseError: LocalizedError {
        let message: String
        let line: Int
        var errorDescription: String? { "YAML error on line \(line): \(message)" }
    }

    /// When parsing with `keepOrder`, every mapping carries its key order under this (non-printable) key.
    static let orderKey = "\u{1}order"

    static func parse(_ text: String) throws -> Any {
        try parse(text, keepOrder: false)
    }

    static func parse(_ text: String, keepOrder: Bool) throws -> Any {
        var p = YAMLParser(text: text, keepOrder: keepOrder)
        return try p.parseDocument()
    }

    /// Keys of a parsed mapping, in document order when available (sorted otherwise). Never includes `orderKey`.
    static func keys(_ d: [String: Any]) -> [String] {
        if let o = d[orderKey] as? [String] { return o.filter { d[$0] != nil } }
        return d.keys.filter { $0 != orderKey }.sorted()
    }

    /// Resolves plain (unquoted) scalars to null / bool / int / float, otherwise returns the string.
    static func typedScalar(_ s: String) -> Any {
        switch s {
        case "", "~", "null", "Null", "NULL": return NSNull()
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: break
        }
        guard let f = s.utf8.first, f == UInt8(ascii: "-") || f == UInt8(ascii: "+") || f == UInt8(ascii: ".") || (f >= 48 && f <= 57)
        else { return s }
        if s.range(of: #"^[-+]?[0-9]+$"#, options: .regularExpression) != nil {
            if let i = Int(s.hasPrefix("+") ? String(s.dropFirst()) : s) { return NSNumber(value: i) }
            if let d = Double(s) { return NSNumber(value: d) }
        }
        if s.hasPrefix("0x"), let i = Int(s.dropFirst(2), radix: 16) { return NSNumber(value: i) }
        if s.hasPrefix("0o"), let i = Int(s.dropFirst(2), radix: 8) { return NSNumber(value: i) }
        if s.range(of: #"^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil,
           let d = Double(s) {
            return NSNumber(value: d)
        }
        return s
    }
}

private struct YAMLParser {
    private let b: [UInt8]
    private var starts: [Int] = []   // offset of each line's first byte
    private var ends: [Int] = []     // offset just past each line's last content byte (excludes \r\n)
    private var li = 0
    /// "- key: v" support: treat line `ovLine` as starting at column `ovCol` (an absolute offset).
    private var ovLine = -1
    private var ovCol = 0
    private var anchors: [String: Any] = [:]
    private let keepOrder: Bool
    private var depth = 0

    private static let sp = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), nl = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")
    private static let hash = UInt8(ascii: "#"), colon = UInt8(ascii: ":"), dash = UInt8(ascii: "-"), comma = UInt8(ascii: ",")
    private static let dq = UInt8(ascii: "\""), sq = UInt8(ascii: "'"), bs = UInt8(ascii: "\\")
    private static let lbrack = UInt8(ascii: "["), rbrack = UInt8(ascii: "]"), lbrace = UInt8(ascii: "{"), rbrace = UInt8(ascii: "}")
    private static let amp = UInt8(ascii: "&"), star = UInt8(ascii: "*"), bang = UInt8(ascii: "!"), pipe = UInt8(ascii: "|"), gt = UInt8(ascii: ">")

    init(text: String, keepOrder: Bool) {
        var bytes = Array(text.utf8)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        b = bytes
        self.keepOrder = keepOrder
        var s = 0
        for (i, c) in b.enumerated() where c == Self.nl {
            starts.append(s)
            ends.append(i > s && b[i - 1] == Self.cr ? i - 1 : i)
            s = i + 1
        }
        if s < b.count { starts.append(s); ends.append(b[b.count - 1] == Self.cr ? b.count - 1 : b.count) }
    }

    // MARK: Line helpers

    private func fail(_ msg: String, line: Int? = nil) -> YAML.ParseError {
        YAML.ParseError(message: msg, line: (line ?? li) + 1)
    }

    private func contentStart(_ l: Int) -> Int {
        if l == ovLine { return ovCol }
        var p = starts[l]
        while p < ends[l], b[p] == Self.sp || b[p] == Self.tab { p += 1 }
        return p
    }

    private func indent(_ l: Int) -> Int { contentStart(l) - starts[l] }

    private func isBlank(_ l: Int) -> Bool {
        let s = contentStart(l)
        return s >= ends[l] || b[s] == Self.hash
    }

    private func isDocMarker(_ l: Int) -> Bool {
        let s = starts[l], e = ends[l]
        guard e - s >= 3, l != ovLine else { return false }
        let three = Array(b[s..<s + 3])
        guard three == [Self.dash, Self.dash, Self.dash] || three == [46, 46, 46] else { return false }
        return e - s == 3 || b[s + 3] == Self.sp || b[s + 3] == Self.tab
    }

    private mutating func skipBlank() {
        while li < starts.count, isBlank(li) { li += 1 }
    }

    private func atEnd() -> Bool { li >= starts.count || isDocMarker(li) }

    private func isSeqItem(_ l: Int) -> Bool {
        let s = contentStart(l)
        return s < ends[l] && b[s] == Self.dash && (s + 1 == ends[l] || b[s + 1] == Self.sp || b[s + 1] == Self.tab)
    }

    private func lineOf(_ offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func str(_ a: Int, _ e: Int) -> String {
        a >= e ? "" : String(decoding: b[a..<e], as: UTF8.self)
    }

    /// End of plain content on line `l` starting at `p`: stops before " #" comments, trailing spaces trimmed.
    private func plainEnd(_ p: Int, _ l: Int) -> Int {
        var e = p
        let end = ends[l]
        while e < end {
            if b[e] == Self.hash, e > 0, b[e - 1] == Self.sp || b[e - 1] == Self.tab { break }
            e += 1
        }
        while e > p, b[e - 1] == Self.sp || b[e - 1] == Self.tab { e -= 1 }
        return e
    }

    /// If line `l` is `key: ...`, returns the key and the offset just past the colon.
    private func keyOf(_ l: Int) throws -> (String, Int)? {
        let s = contentStart(l), e = ends[l]
        guard s < e else { return nil }
        let c = b[s]
        if c == Self.dq || c == Self.sq {
            var p = s
            let key: String
            do { key = try quoted(&p) } catch { return nil }
            guard lineOf(p) == l || p == b.count else { return nil }
            while p < e, b[p] == Self.sp || b[p] == Self.tab { p += 1 }
            guard p < e, b[p] == Self.colon, p + 1 == e || b[p + 1] == Self.sp || b[p + 1] == Self.tab else { return nil }
            return (key, p + 1)
        }
        if c == Self.lbrack || c == Self.lbrace || c == Self.hash || c == Self.star || c == Self.pipe || c == Self.gt { return nil }
        if c == UInt8(ascii: "?"), s + 1 == e || b[s + 1] == Self.sp { throw fail("complex keys are not supported") }
        var p = s
        while p < e {
            if b[p] == Self.hash, p > s, b[p - 1] == Self.sp || b[p - 1] == Self.tab { return nil }
            if b[p] == Self.colon, p + 1 == e || b[p + 1] == Self.sp || b[p + 1] == Self.tab {
                var ke = p
                while ke > s, b[ke - 1] == Self.sp || b[ke - 1] == Self.tab { ke -= 1 }
                return (str(s, ke), p + 1)
            }
            p += 1
        }
        return nil
    }

    // MARK: Document / block structure

    mutating func parseDocument() throws -> Any {
        // Directives and leading document marker.
        while li < starts.count {
            if isBlank(li) { li += 1; continue }
            let s = contentStart(li)
            if s == starts[li], b[s] == UInt8(ascii: "%") { li += 1; continue }
            if isDocMarker(li), b[starts[li]] == Self.dash {
                let rest = contentStart(li) + 3
                let p = skipSpaces(rest, li)
                if p < ends[li], b[p] != Self.hash {
                    // "--- value" / "--- |" on the marker line.
                    ovLine = li; ovCol = p
                    break
                }
                li += 1; continue
            }
            break
        }
        skipBlank()
        if atEnd() { return NSNull() }
        let root = try parseBlock(minIndent: 0)
        skipBlank()
        if li < starts.count, !isDocMarker(li) { throw fail("unexpected content") }
        return root
    }

    private func skipSpaces(_ p0: Int, _ l: Int) -> Int {
        var p = p0
        while p < ends[l], b[p] == Self.sp || b[p] == Self.tab { p += 1 }
        return p
    }

    private mutating func enter() throws {
        depth += 1
        if depth > 200 { throw fail("nesting too deep") }
    }

    /// Parses the node starting at the next non-blank line, which must be indented at least `minIndent`.
    private mutating func parseBlock(minIndent: Int) throws -> Any {
        try enter(); defer { depth -= 1 }
        skipBlank()
        if atEnd() || indent(li) < minIndent { return NSNull() }
        let n = indent(li)
        if isSeqItem(li) { return try parseSeq(n) }
        if try keyOf(li) != nil { return try parseMap(n) }
        return try parseValue(at: contentStart(li), parentIndent: minIndent - 1, inMap: false)
    }

    private mutating func parseMap(_ n: Int) throws -> Any {
        var dict: [String: Any] = [:]
        var order: [String] = []
        func set(_ k: String, _ v: Any) {
            if dict[k] == nil { order.append(k) }
            dict[k] = v
        }
        while true {
            skipBlank()
            if atEnd() { break }
            let ind = indent(li)
            if ind < n { break }
            if ind > n { throw fail("unexpected indentation") }
            if isSeqItem(li) { break }
            guard let (key, vs) = try keyOf(li) else { throw fail("expected a 'key: value' pair") }
            let value = try parseValue(at: vs, parentIndent: n, inMap: true)
            if key == "<<" {
                let sources = (value as? [Any]) ?? [value]
                for src in sources {
                    guard let m = src as? [String: Any] else { continue }
                    for k in YAML.keys(m) where dict[k] == nil { set(k, m[k]!) }
                }
            } else {
                set(key, value)
            }
        }
        if keepOrder { dict[YAML.orderKey] = order }
        return dict
    }

    private mutating func parseSeq(_ n: Int) throws -> Any {
        var items: [Any] = []
        while true {
            skipBlank()
            if atEnd() { break }
            let ind = indent(li)
            if ind < n { break }
            if ind > n { throw fail("unexpected indentation") }
            guard isSeqItem(li) else { break }
            let p = skipSpaces(contentStart(li) + 1, li)
            if p >= ends[li] || b[p] == Self.hash {
                li += 1
                items.append(try parseBlock(minIndent: n + 1))
                continue
            }
            // Inline "- key: v" or "- - x": re-read this line as if it started at `p`.
            let saved = (ovLine, ovCol)
            ovLine = li; ovCol = p
            let col = p - starts[li]
            if isSeqItem(li) {
                try enter(); defer { depth -= 1 }
                items.append(try parseSeq(col))
            } else if try keyOf(li) != nil {
                try enter(); defer { depth -= 1 }
                items.append(try parseMap(col))
            } else {
                (ovLine, ovCol) = saved
                items.append(try parseValue(at: p, parentIndent: n, inMap: false))
            }
        }
        return items
    }

    /// Parses the value following "key:" or "- " at offset `vs` on the current line.
    private mutating func parseValue(at vs: Int, parentIndent n: Int, inMap: Bool) throws -> Any {
        let l = li
        var p = skipSpaces(vs, l)
        var anchor: String?
        // Anchors and tags (tags are ignored).
        while p < ends[l], b[p] == Self.amp || b[p] == Self.bang {
            let isAnchor = b[p] == Self.amp
            var e = p + 1
            while e < ends[l], b[e] != Self.sp, b[e] != Self.tab { e += 1 }
            if isAnchor { anchor = str(p + 1, e) }
            p = skipSpaces(e, l)
        }
        let value: Any
        if p >= ends[l] || b[p] == Self.hash {
            li += 1
            skipBlank()
            if !atEnd(), inMap, indent(li) == n, isSeqItem(li) {
                value = try parseSeq(n)
            } else {
                value = try parseBlock(minIndent: n + 1)
            }
        } else if b[p] == Self.star {
            var e = p + 1
            while e < ends[l], b[e] != Self.sp, b[e] != Self.tab, b[e] != Self.comma { e += 1 }
            let name = str(p + 1, e)
            guard let v = anchors[name] else { throw fail("unknown alias '\(name)'") }
            li += 1
            value = v
        } else if b[p] == Self.pipe || b[p] == Self.gt {
            value = try blockScalar(at: p, parentIndent: n)
        } else if b[p] == Self.lbrack || b[p] == Self.lbrace {
            var q = p
            value = try flowNode(&q)
            try finishInline(q)
        } else if b[p] == Self.dq || b[p] == Self.sq {
            var q = p
            value = try quoted(&q)
            try finishInline(q)
        } else {
            var parts = [str(p, plainEnd(p, l))]
            li += 1
            // Multi-line plain scalar: continuation lines indented deeper than the parent.
            var blankRun = 0
            while li < starts.count, !isDocMarker(li) {
                if contentStart(li) >= ends[li] { blankRun += 1; li += 1; continue }
                let s = contentStart(li)
                if indent(li) <= n || b[s] == Self.hash { break }
                if try keyOf(li) != nil { break }
                if blankRun > 0 { parts.append(String(repeating: "\n", count: blankRun)) }
                blankRun = 0
                parts.append(str(s, plainEnd(s, li)))
                li += 1
            }
            if parts.count == 1 {
                value = YAML.typedScalar(parts[0])
            } else {
                var out = ""
                for (i, part) in parts.enumerated() {
                    if i > 0, !part.hasPrefix("\n"), !(out.hasSuffix("\n")) { out += " " }
                    out += part
                }
                value = out
            }
        }
        if let a = anchor { anchors[a] = value }
        return value
    }

    /// After an inline flow/quoted value ending at `q`, only a comment may follow on that line.
    private mutating func finishInline(_ q: Int) throws {
        let l = lineOf(max(0, min(q, b.count - 1)))
        let lineEnd = q >= b.count ? b.count : ends[l]
        let p = q >= b.count ? q : skipSpaces(q, l)
        if p < lineEnd, b[p] != Self.hash { throw fail("unexpected characters after value", line: l) }
        li = l + 1
    }

    // MARK: Block scalars

    private mutating func blockScalar(at p0: Int, parentIndent n: Int) throws -> Any {
        let l = li
        let folded = b[p0] == Self.gt
        var chomp: UInt8 = 0
        var explicitIndent: Int?
        var p = p0 + 1
        while p < ends[l], b[p] != Self.sp, b[p] != Self.tab {
            let c = b[p]
            if c == Self.dash || c == UInt8(ascii: "+") { chomp = c }
            else if c >= 49 && c <= 57 { explicitIndent = Int(c - 48) }
            else if c == Self.hash { break }
            else { throw fail("invalid block scalar header") }
            p += 1
        }
        li += 1
        var contentIndent = explicitIndent.map { max(n, 0) + $0 }
        var lines: [String] = []
        while li < starts.count {
            let s = starts[li], e = ends[li]
            var q = s
            while q < e, b[q] == Self.sp { q += 1 }
            let ind = q - s
            if q >= e {
                // Blank line (may contain spaces beyond the content indent).
                let ci = contentIndent ?? Int.max
                lines.append(ind > ci ? str(s + ci, e) : "")
                li += 1
                continue
            }
            if contentIndent == nil {
                if ind <= n { break }
                contentIndent = ind
            }
            guard let ci = contentIndent, ind >= ci, !(ind == 0 && isDocMarker(li)) else { break }
            lines.append(str(s + ci, e))
            li += 1
        }
        // Trailing blank lines
        var trailing = 0
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            trailing += 1; lines.removeLast()
        }
        var text: String
        if folded {
            text = ""
            var pending = 0
            var prevMore = false
            var started = false
            for line in lines {
                if line.isEmpty { pending += 1; continue }
                let more = line.hasPrefix(" ") || line.hasPrefix("\t")
                if started {
                    if pending == 0 { text += (more || prevMore) ? "\n" : " " }
                    else { text += String(repeating: "\n", count: pending + ((more || prevMore) ? 1 : 0)) }
                } else if pending > 0 {
                    text += String(repeating: "\n", count: pending)
                }
                text += line
                pending = 0
                prevMore = more
                started = true
            }
        } else {
            text = lines.joined(separator: "\n")
        }
        if lines.isEmpty { return chomp == UInt8(ascii: "+") ? String(repeating: "\n", count: trailing) : "" }
        switch chomp {
        case Self.dash: break
        case UInt8(ascii: "+"): text += String(repeating: "\n", count: trailing + 1)
        default: text += "\n"
        }
        return text
    }

    // MARK: Quoted scalars

    /// Parses a quoted scalar starting at `p` (the quote). Leaves `p` just past the closing quote. May span lines.
    private func quoted(_ p: inout Int) throws -> String {
        let q = b[p]
        let startLine = lineOf(p)
        p += 1
        var out: [UInt8] = []
        while true {
            guard p < b.count else { throw fail("unterminated quoted string", line: startLine) }
            let c = b[p]
            if c == q {
                if q == Self.sq, p + 1 < b.count, b[p + 1] == Self.sq { out.append(Self.sq); p += 2; continue }
                p += 1
                break
            }
            if c == Self.cr || c == Self.nl {
                // Fold line breaks: trailing spaces dropped, one break → space, extra blank lines → newlines.
                while let last = out.last, last == Self.sp || last == Self.tab { out.removeLast() }
                var breaks = 0
                while p < b.count, b[p] == Self.cr || b[p] == Self.nl || b[p] == Self.sp || b[p] == Self.tab {
                    if b[p] == Self.nl { breaks += 1 }
                    p += 1
                }
                if breaks <= 1 { out.append(Self.sp) } else { out.append(contentsOf: Array(repeating: Self.nl, count: breaks - 1)) }
                continue
            }
            if q == Self.dq, c == Self.bs {
                guard p + 1 < b.count else { throw fail("bad escape") }
                let e = b[p + 1]
                p += 2
                switch e {
                case UInt8(ascii: "n"): out.append(Self.nl)
                case UInt8(ascii: "t"), Self.tab: out.append(Self.tab)
                case UInt8(ascii: "r"): out.append(Self.cr)
                case UInt8(ascii: "0"): out.append(0)
                case UInt8(ascii: "b"): out.append(8)
                case UInt8(ascii: "f"): out.append(12)
                case UInt8(ascii: "v"): out.append(11)
                case UInt8(ascii: "a"): out.append(7)
                case UInt8(ascii: "e"): out.append(27)
                case UInt8(ascii: "N"): out.append(contentsOf: Array("\u{85}".utf8))
                case UInt8(ascii: "_"): out.append(contentsOf: Array("\u{A0}".utf8))
                case UInt8(ascii: "x"), UInt8(ascii: "u"), UInt8(ascii: "U"):
                    let len = e == UInt8(ascii: "x") ? 2 : e == UInt8(ascii: "u") ? 4 : 8
                    var code = try hex(&p, len)
                    // UTF-16 surrogate pair (JSON style).
                    if code >= 0xD800, code < 0xDC00, p + 5 < b.count, b[p] == Self.bs, b[p + 1] == UInt8(ascii: "u") {
                        var p2 = p + 2
                        let lo = try hex(&p2, 4)
                        if lo >= 0xDC00, lo < 0xE000 {
                            code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
                            p = p2
                        }
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                case Self.cr, Self.nl:
                    // Escaped line break: join without a space.
                    while p < b.count, b[p] == Self.cr || b[p] == Self.nl || b[p] == Self.sp || b[p] == Self.tab { p += 1 }
                default: out.append(e)  // \" \\ \/ \space and unknowns
                }
                continue
            }
            out.append(c)
            p += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func hex(_ p: inout Int, _ len: Int) throws -> UInt32 {
        guard p + len <= b.count, let v = UInt32(str(p, p + len), radix: 16) else { throw fail("bad unicode escape") }
        p += len
        return v
    }

    // MARK: Flow collections

    private func skipFlowSpace(_ p: inout Int) {
        while p < b.count {
            let c = b[p]
            if c == Self.sp || c == Self.tab || c == Self.nl || c == Self.cr { p += 1; continue }
            if c == Self.hash, p == 0 || [Self.sp, Self.tab, Self.nl, Self.cr].contains(b[p - 1]) {
                while p < b.count, b[p] != Self.nl { p += 1 }
                continue
            }
            break
        }
    }

    private mutating func flowNode(_ p: inout Int) throws -> Any {
        try enter(); defer { depth -= 1 }
        skipFlowSpace(&p)
        guard p < b.count else { throw fail("unexpected end of input in flow collection") }
        var anchor: String?
        while p < b.count, b[p] == Self.amp || b[p] == Self.bang {
            let isAnchor = b[p] == Self.amp
            var e = p + 1
            while e < b.count, ![Self.sp, Self.tab, Self.nl, Self.cr, Self.comma, Self.rbrack, Self.rbrace].contains(b[e]) { e += 1 }
            if isAnchor { anchor = str(p + 1, e) }
            p = e
            skipFlowSpace(&p)
        }
        guard p < b.count else { throw fail("unexpected end of input in flow collection") }
        let value: Any
        switch b[p] {
        case Self.lbrack:
            p += 1
            var items: [Any] = []
            while true {
                skipFlowSpace(&p)
                guard p < b.count else { throw fail("unterminated '['") }
                if b[p] == Self.rbrack { p += 1; break }
                var item = try flowNode(&p)
                skipFlowSpace(&p)
                // Single-pair implicit map inside a sequence: [a: 1]
                if p < b.count, b[p] == Self.colon {
                    p += 1
                    skipFlowSpace(&p)
                    let v: Any = (p < b.count && (b[p] == Self.comma || b[p] == Self.rbrack)) ? NSNull() : try flowNode(&p)
                    var m: [String: Any] = [flowKey(item): v]
                    if keepOrder { m[YAML.orderKey] = [flowKey(item)] }
                    item = m
                    skipFlowSpace(&p)
                }
                items.append(item)
                guard p < b.count else { throw fail("unterminated '['") }
                if b[p] == Self.comma { p += 1 } else if b[p] != Self.rbrack { throw fail("expected ',' or ']'", line: lineOf(p)) }
            }
            value = items
        case Self.lbrace:
            p += 1
            var dict: [String: Any] = [:]
            var order: [String] = []
            while true {
                skipFlowSpace(&p)
                guard p < b.count else { throw fail("unterminated '{'") }
                if b[p] == Self.rbrace { p += 1; break }
                let key = flowKey(try flowNode(&p))
                skipFlowSpace(&p)
                var v: Any = NSNull()
                if p < b.count, b[p] == Self.colon {
                    p += 1
                    skipFlowSpace(&p)
                    if p < b.count, b[p] != Self.comma, b[p] != Self.rbrace { v = try flowNode(&p) }
                    skipFlowSpace(&p)
                }
                if dict[key] == nil { order.append(key) }
                dict[key] = v
                guard p < b.count else { throw fail("unterminated '{'") }
                if b[p] == Self.comma { p += 1 } else if b[p] != Self.rbrace { throw fail("expected ',' or '}'", line: lineOf(p)) }
            }
            if keepOrder { dict[YAML.orderKey] = order }
            value = dict
        case Self.dq, Self.sq:
            value = try quoted(&p)
        case Self.star:
            var e = p + 1
            while e < b.count, ![Self.sp, Self.tab, Self.nl, Self.cr, Self.comma, Self.rbrack, Self.rbrace].contains(b[e]) { e += 1 }
            let name = str(p + 1, e)
            guard let v = anchors[name] else { throw fail("unknown alias '\(name)'", line: lineOf(p)) }
            p = e
            value = v
        case Self.rbrack, Self.rbrace, Self.comma:
            throw fail("unexpected '\(Character(Unicode.Scalar(b[p])))'", line: lineOf(p))
        default:
            // Plain scalar: ends at , ] } newline, " #", or ':' followed by space/flow indicator.
            let s = p
            while p < b.count {
                let c = b[p]
                if c == Self.comma || c == Self.rbrack || c == Self.rbrace || c == Self.nl || c == Self.cr { break }
                if c == Self.colon, p + 1 >= b.count || [Self.sp, Self.tab, Self.nl, Self.cr, Self.comma, Self.rbrack, Self.rbrace].contains(b[p + 1]) { break }
                if c == Self.hash, p > s, b[p - 1] == Self.sp || b[p - 1] == Self.tab { break }
                p += 1
            }
            var e = p
            while e > s, b[e - 1] == Self.sp || b[e - 1] == Self.tab { e -= 1 }
            value = YAML.typedScalar(str(s, e))
        }
        if let a = anchor { anchors[a] = value }
        return value
    }

    private func flowKey(_ v: Any) -> String {
        if let s = v as? String { return s }
        if v is NSNull { return "" }
        if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue }
        return "\(v)"
    }
}
