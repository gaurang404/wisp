import AppKit

enum JSONFormat {
    /// Pretty-prints JSON while preserving key order. Returns nil if `s` isn't valid JSON.
    static func pretty(_ s: String, indent: Int = 2) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let d = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) != nil
        else { return nil }

        // Byte-level pass: every structural JSON character is ASCII, so UTF-8 inside strings is copied verbatim.
        let bytes = Array(trimmed.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        var level = 0
        var inString = false
        var escaped = false
        func newline() {
            out.append(0x0A)
            out.append(contentsOf: repeatElement(0x20, count: level * indent))
        }
        var i = 0
        let n = bytes.count
        while i < n {
            let c = bytes[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == 0x5C { escaped = true }          // \
                else if c == 0x22 { inString = false }        // "
            } else {
                switch c {
                case 0x22:                                    // "
                    inString = true
                    out.append(c)
                case 0x7B, 0x5B:                              // { [
                    var j = i + 1
                    while j < n, bytes[j] == 0x20 || bytes[j] == 0x0A || bytes[j] == 0x0D || bytes[j] == 0x09 { j += 1 }
                    if j < n, bytes[j] == 0x7D || bytes[j] == 0x5D {
                        out.append(c); out.append(bytes[j]); i = j
                    } else {
                        out.append(c); level += 1; newline()
                    }
                case 0x7D, 0x5D:                              // } ]
                    level -= 1; newline(); out.append(c)
                case 0x2C:                                    // ,
                    out.append(c); newline()
                case 0x3A:                                    // :
                    out.append(0x3A); out.append(0x20)
                case 0x20, 0x0A, 0x0D, 0x09:
                    break
                default:
                    out.append(c)
                }
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Tiny path query: `data.items[0].name`, `items.name` (maps over arrays), `items.#` (count), `$` prefix optional.
    static func query(_ data: Data, path: String) -> String? {
        guard var node = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("$") { p.removeFirst() }
        let tokens = p.replacingOccurrences(of: "[", with: ".")
            .replacingOccurrences(of: "]", with: "")
            .split(separator: ".").map(String.init)

        for tok in tokens {
            if tok == "#" {
                if let a = node as? [Any] { node = a.count }
                else if let d = node as? [String: Any] { node = d.count }
                else { return nil }
            } else if let idx = Int(tok), let arr = node as? [Any] {
                let k = idx < 0 ? arr.count + idx : idx
                guard arr.indices.contains(k) else { return nil }
                node = arr[k]
            } else if let dict = node as? [String: Any] {
                guard let v = dict[tok] else { return nil }
                node = v
            } else if let arr = node as? [Any] {
                node = arr.compactMap { ($0 as? [String: Any])?[tok] }
            } else {
                return nil
            }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: node, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys])
        else { return nil }
        let s = String(decoding: out, as: UTF8.self)
        return pretty(s) ?? s
    }

    // MARK: - Highlighting

    static let highlightLimit = 4_000_000   // ≈ 2–3 MB of JSON; ~60 ms on Apple silicon

    private enum Token { case key, string, number, literal }

    /// Single pass over UTF-16 (NSString ranges): keys, strings, numbers, true/false/null.
    private static func tokens(_ u: [UInt16]) -> [(NSRange, Token)] {
        var out: [(NSRange, Token)] = []
        out.reserveCapacity(u.count / 8)
        let n = u.count
        var i = 0
        func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
        func isWordChar(_ c: UInt16) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || isDigit(c) || c == 0x5F }
        while i < n {
            let c = u[i]
            if c == 0x22 {                                     // string or key
                var j = i + 1
                while j < n, u[j] != 0x22, u[j] != 0x0A {
                    if u[j] == 0x5C { j += 1 }
                    j += 1
                }
                guard j < n, u[j] == 0x22 else { i = j; continue }   // unterminated on this line
                var k = j + 1
                while k < n, u[k] == 0x20 || u[k] == 0x09 { k += 1 }
                out.append((NSRange(location: i, length: j - i + 1), k < n && u[k] == 0x3A ? .key : .string))
                i = j + 1
            } else if isDigit(c) || (c == 0x2D && i + 1 < n && isDigit(u[i + 1])) {
                guard i == 0 || !isWordChar(u[i - 1]) else { i += 1; continue }
                var j = i + 1
                while j < n, isDigit(u[j]) || u[j] == 0x2E || u[j] == 0x65 || u[j] == 0x45 || u[j] == 0x2B || u[j] == 0x2D { j += 1 }
                out.append((NSRange(location: i, length: j - i), .number))
                i = j
            } else if c == 0x74 || c == 0x66 || c == 0x6E {   // t f n
                var j = i
                while j < n, isWordChar(u[j]) { j += 1 }
                let word = String(decoding: u[i..<j], as: UTF16.self)
                if (word == "true" || word == "false" || word == "null"), i == 0 || !isWordChar(u[i - 1]) {
                    out.append((NSRange(location: i, length: j - i), .literal))
                }
                i = max(j, i + 1)
            } else {
                i += 1
            }
        }
        return out
    }

    static func highlight(_ storage: NSTextStorage) {
        let s = storage.string as NSString
        let full = NSRange(location: 0, length: s.length)
        guard full.length <= highlightLimit else { return }
        var u = [UInt16](repeating: 0, count: full.length)
        s.getCharacters(&u, range: full)
        let found = tokens(u)
        let colors: [Token: NSColor] = [.key: .systemBlue, .string: .systemOrange, .number: .systemPurple, .literal: .systemPink]
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
        for (range, token) in found { storage.addAttribute(.foregroundColor, value: colors[token]!, range: range) }
        storage.endEditing()
    }
}
