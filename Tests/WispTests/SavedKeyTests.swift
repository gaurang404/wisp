import XCTest
@testable import Wisp

final class SavedKeyTests: XCTestCase {
    private func env(_ apiKey: String) -> EnvSet {
        EnvSet(name: "api.example.com", vars: [
            KeyValue(key: "baseUrl", value: "https://api.example.com"),
            KeyValue(key: "apiKey", value: apiKey, secret: true),
        ])
    }

    func testKeyInUseAndSwitching() {
        var e = env("AAA")
        XCTAssertTrue(e.hasUnsavedKey)
        let a = SavedKey(name: "Personal", credentials: e.credentials)
        let b = SavedKey(name: "Team", credentials: ["apiKey": "BBB"])
        e.keys = [a, b]
        XCTAssertEqual(e.keyInUse?.id, a.id)
        e.use(b)
        XCTAssertEqual(e.keyInUse?.id, b.id)
        XCTAssertEqual(e.credentials["apiKey"], "BBB")
        XCTAssertEqual(e.vars.first { $0.key == "baseUrl" }?.value, "https://api.example.com")   // only secrets change
    }

    func testDeleteKeyInUseSwitchesOrBlanks() {
        var e = env("AAA")
        let a = SavedKey(name: "Key 1", credentials: ["apiKey": "AAA"])
        let b = SavedKey(name: "Key 2", credentials: ["apiKey": "BBB"])
        e.keys = [a, b]
        e.deleteKey(a.id)
        XCTAssertEqual(e.keyInUse?.id, b.id)
        e.deleteKey(b.id)
        XCTAssertTrue(e.keys.isEmpty)
        XCTAssertTrue(e.credentials.isEmpty)   // never sent again
    }

    func testDeleteOtherKeyLeavesInUse() {
        var e = env("AAA")
        let a = SavedKey(name: "Key 1", credentials: ["apiKey": "AAA"])
        let b = SavedKey(name: "Key 2", credentials: ["apiKey": "BBB"])
        e.keys = [a, b]
        e.deleteKey(b.id)
        XCTAssertEqual(e.keyInUse?.id, a.id)
        XCTAssertEqual(e.nextKeyName, "Key 2")
    }

    func testOldStateDecodesWithoutKeys() throws {
        let json = #"{"name":"Old","vars":[]}"#
        let e = try JSONDecoder().decode(EnvSet.self, from: Data(json.utf8))
        XCTAssertEqual(e.name, "Old")
        XCTAssertTrue(e.keys.isEmpty)
    }

    func testEditingSecretVariableEditsKeyInUse() {
        var e = env("AAA")
        let a = SavedKey(name: "Main", credentials: ["apiKey": "AAA"])
        let b = SavedKey(name: "Test", credentials: ["apiKey": "BBB"])
        e.keys = [a, b]
        let old = e
        e.vars[1].value = "AAA2"
        e.syncKeyInUse(from: old)
        XCTAssertEqual(e.keyInUse?.id, a.id)              // no drift to "unsaved"
        XCTAssertEqual(e.keys[0].values.first?.id, a.values.first?.id)   // same Keychain slot
        XCTAssertEqual(e.keys[1].credentials["apiKey"], "BBB")   // other keys untouched
    }

    func testPlainVariableEditDoesNotTouchKeys() {
        var e = env("AAA")
        e.keys = [SavedKey(name: "Main", credentials: ["apiKey": "AAA"])]
        let old = e
        e.vars[0].value = "https://staging.example.com"
        e.syncKeyInUse(from: old)
        XCTAssertEqual(e.keys, old.keys)
    }

    func testOldHistoryDecodesWithoutEnvironment() throws {
        let json = #"{"request":{"url":"https://x.dev"},"status":200,"duration":0.1}"#
        let h = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        XCTAssertNil(h.envID)
        XCTAssertNil(h.keyName)
    }
}
