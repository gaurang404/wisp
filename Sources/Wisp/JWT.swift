import Foundation

struct JWTInfo {
    var header: String
    var payload: String
    var expiresAt: Date?
    var issuedAt: Date?
    var isExpired: Bool
    var subject: String?
    var issuer: String?
}

enum JWT {
    /// Decodes (does not verify) a JWS compact token. Tolerates a "Bearer " prefix and surrounding whitespace.
    static func decode(_ token: String) -> JWTInfo? {
        var t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("bearer ") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let h = base64URLDecode(parts[0]), let p = base64URLDecode(parts[1]),
              let hObj = (try? JSONSerialization.jsonObject(with: h)) as? [String: Any], hObj["alg"] != nil,
              let pObj = (try? JSONSerialization.jsonObject(with: p)) as? [String: Any]
        else { return nil }
        func date(_ key: String) -> Date? {
            if let n = pObj[key] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
            if let s = pObj[key] as? String, let d = Double(s) { return Date(timeIntervalSince1970: d) }
            return nil
        }
        let hText = String(decoding: h, as: UTF8.self), pText = String(decoding: p, as: UTF8.self)
        let exp = date("exp")
        return JWTInfo(
            header: JSONFormat.pretty(hText) ?? hText,
            payload: JSONFormat.pretty(pText) ?? pText,
            expiresAt: exp,
            issuedAt: date("iat"),
            isExpired: exp.map { $0 < Date() } ?? false,
            subject: pObj["sub"] as? String,
            issuer: pObj["iss"] as? String
        )
    }

    private static let candidate = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_\-.])[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{2,}\.[A-Za-z0-9_\-]*(?![A-Za-z0-9_\-.])"#)

    /// First JWT-looking string in arbitrary text (three base64url segments whose header is JSON with "alg").
    static func find(in text: String) -> String? {
        let ns = text as NSString
        for m in candidate.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            if decode(s) != nil { return s }
        }
        return nil
    }

    static func base64URLDecode<S: StringProtocol>(_ s: S) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if b.count % 4 == 1 { return nil }
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }
}
