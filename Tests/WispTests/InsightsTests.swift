import XCTest
@testable import Wisp

final class InsightsTests: XCTestCase {
    private func texts(status: Int = 200, _ headers: [(String, String)], body: String = "{}") -> [ResponseInsight] {
        Insights.from(status: status, headers: headers, body: Data(body.utf8))
    }

    func testShopifyCallLimit() {
        let ok = texts([("X-Shopify-Shop-Api-Call-Limit", "4/40")])
        XCTAssertTrue(ok.contains { $0.text.contains("4/40") && $0.level == .info })
        let hot = texts([("x-shopify-shop-api-call-limit", "36/40")])
        XCTAssertTrue(hot.contains { $0.text.contains("36/40") && $0.level == .warning })
    }

    func testRequestIDIsCopyable() {
        let i = texts([("Request-Id", "req_123")])
        XCTAssertEqual(i.first { $0.text == "Request ID" }?.copyValue, "req_123")
    }

    func testGenericRateLimitAndRetryAfter() {
        let rate = texts([("X-RateLimit-Remaining", "3"), ("X-RateLimit-Limit", "60")])
        XCTAssertTrue(rate.contains { $0.level == .warning })
        let throttled = texts(status: 429, [("Retry-After", "30")])
        XCTAssertTrue(throttled.contains { $0.text.contains("30") })
    }

    func testWordPressTotals() {
        XCTAssertTrue(texts([("X-WP-Total", "312"), ("X-WP-TotalPages", "7")]).contains { $0.text.contains("312") && $0.text.contains("7") })
    }

    func testCappedAtFour() {
        let many = texts(status: 429, [("Retry-After", "5"), ("X-Shopify-API-Deprecated-Reason", "x"), ("X-Shopify-Shop-Api-Call-Limit", "39/40"),
                                ("X-RateLimit-Remaining", "1"), ("X-RateLimit-Limit", "60"), ("Request-Id", "r"), ("Stripe-Version", "2026-01-01")])
        XCTAssertLessThanOrEqual(many.count, 4)
    }

    func testHugeUntouchedQuotaIsHidden() {
        XCTAssertFalse(texts([("X-RateLimit-Remaining", "3599999"), ("X-RateLimit-Limit", "3600000")]).contains { $0.text.hasPrefix("Rate") })
        XCTAssertTrue(texts([("X-RateLimit-Remaining", "50"), ("X-RateLimit-Limit", "60")]).contains { $0.text.hasPrefix("Rate") })
        XCTAssertTrue(texts([("X-RateLimit-Remaining", "1000"), ("X-RateLimit-Limit", "5000")]).contains { $0.text.hasPrefix("Rate") })
    }
}
