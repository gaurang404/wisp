import Foundation

// MARK: - Response insights

struct ResponseInsight: Hashable, Identifiable {
    enum Level: Hashable { case info, warning }
    var id: String { icon + text }
    var icon: String
    var text: String
    var level: Level
    var help: String
    var copyValue: String?
}

enum Insights {
    static func from(status: Int, headers: [(String, String)], body: Data) -> [ResponseInsight] {
        func h(_ name: String) -> String? {
            headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1.trimmingCharacters(in: .whitespaces)
        }
        func int(_ name: String) -> Int? { h(name).flatMap { Int($0) } }
        var out: [ResponseInsight] = []
        func add(_ icon: String, _ text: String, _ warn: Bool, _ help: String, copy: String? = nil) {
            out.append(ResponseInsight(icon: icon, text: text, level: warn ? .warning : .info, help: help, copyValue: copy))
        }
        func low(_ left: Int, of max: Int?) -> Bool { left <= 0 || (max.map { $0 > 0 && left * 5 < $0 } ?? false) }

        if status == 429 {
            let wait = h("Retry-After").map { Int($0).map { "Retry in \($0)s" } ?? "Retry after \($0)" } ?? "Rate limited"
            add("hourglass", wait, true, "Too many requests. Wait before retrying.")
        }
        if let reason = h("X-Shopify-API-Deprecated-Reason") {
            add("exclamationmark.triangle.fill", "Deprecated API", true, "Shopify: \(reason)")
        }
        // Shopify REST leaky bucket, e.g. "32/40".
        if let limit = h("X-Shopify-Shop-Api-Call-Limit") {
            let parts = limit.split(separator: "/").compactMap { Int($0) }
            let warn = parts.count == 2 && parts[1] > 0 && parts[0] * 5 >= parts[1] * 4
            add("gauge.with.needle", "API \(limit)", warn, "Shopify REST calls used / bucket size. The bucket refills over time; slow down near the top.")
        }
        // Shopify GraphQL cost.
        if let cost = graphQLCost(body) {
            add("gauge.with.needle", cost.text, cost.low,
                "Shopify GraphQL query cost and remaining throttle points (restores over time).")
        }
        // BigCommerce.
        if let left = int("X-Rate-Limit-Requests-Left") {
            let quota = int("X-Rate-Limit-Requests-Quota")
            let reset = int("X-Rate-Limit-Time-Reset-Ms").map { String(format: " Resets in %.1fs.", Double($0) / 1000) } ?? ""
            add("gauge.with.needle", "Rate \(left)\(quota.map { "/\($0)" } ?? "") left", low(left, of: quota),
                "Requests left in the current rate-limit window.\(reset)")
        }
        // Generic (GitHub, many others) and IETF RateLimit headers.
        else if let left = int("X-RateLimit-Remaining") ?? int("RateLimit-Remaining") ?? ietfRemaining(h("RateLimit")) {
            let max = int("X-RateLimit-Limit") ?? int("RateLimit-Limit")
            // Only when it matters: small budgets (e.g. 60/hour) or at least half used — a huge untouched quota is noise.
            let matters = max.map { $0 <= 1_000 || left * 2 <= $0 } ?? (left <= 1_000)
            if matters {
                add("gauge.with.needle", "Rate \(left)\(max.map { "/\($0)" } ?? "") left", low(left, of: max),
                    "Requests left in the current rate-limit window.")
            }
        }
        // WooCommerce / WordPress totals.
        if let total = h("X-WP-Total") {
            let pages = h("X-WP-TotalPages").map { " · \($0) \($0 == "1" ? "page" : "pages")" } ?? ""
            add("number", "\(total) items\(pages)", false, "Total items and pages for this query (X-WP-Total / X-WP-TotalPages).")
        }
        if let v = h("Stripe-Version") {
            add("calendar", "Stripe \(v)", false, "Stripe API version used for this request.")
        }
        if let id = h("Request-Id") ?? h("X-Request-Id") ?? h("X-GitHub-Request-Id") {
            add("number.square", "Request ID", false, "\(id) — quote it when contacting the API's support. Click to copy.", copy: id)
        }
        return Array(out.prefix(4))
    }

    private static func graphQLCost(_ body: Data) -> (text: String, low: Bool)? {
        guard body.range(of: Data(#""cost""#.utf8)) != nil,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let cost = (root["extensions"] as? [String: Any])?["cost"] as? [String: Any] else { return nil }
        let used = (cost["actualQueryCost"] as? Int) ?? (cost["requestedQueryCost"] as? Int)
        let throttle = cost["throttleStatus"] as? [String: Any]
        let avail = throttle?["currentlyAvailable"] as? Int
        let max = throttle?["maximumAvailable"] as? Int
        guard used != nil || avail != nil else { return nil }
        var text = "Cost \(used.map(String.init) ?? "?")"
        if let a = avail { text += " · \(a)\(max.map { "/\($0)" } ?? "") left" }
        let low = avail.map { a in max.map { a * 5 < $0 } ?? false } ?? false
        return (text, low)
    }

    /// IETF draft combined header: `RateLimit: limit=100, remaining=50, reset=5`.
    private static func ietfRemaining(_ value: String?) -> Int? {
        guard let value, let r = value.range(of: #"remaining\s*=\s*\d+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(value[r].filter(\.isNumber))
    }
}
