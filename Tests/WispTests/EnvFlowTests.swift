import XCTest
@testable import Wisp

/// End-to-end flows through the real Store (persistence + Keychain), in a throwaway data dir.
/// Sends go to a closed local port: they fail fast, and failures are recorded in history too.
@MainActor
final class EnvFlowTests: XCTestCase {
    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-flow-\(UUID().uuidString)").path

    override class func setUp() {
        setenv("WISP_DATA_DIR", dir, 1)   // before Store.fileURL / Secrets are first read
    }

    override class func tearDown() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Secrets.service, kSecAttrAccount as String: Secrets.account]
        SecItemDelete(q as CFDictionary)
        try? FileManager.default.removeItem(atPath: dir)
    }

    override func setUp() async throws {
        try? FileManager.default.removeItem(at: Store.fileURL)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Secrets.service, kSecAttrAccount as String: Secrets.account]
        SecItemDelete(q as CFDictionary)
    }

    private func freshStore() async -> Store {
        let s = Store()
        for _ in 0..<100 where s.keychainPending { try? await Task.sleep(for: .milliseconds(20)) }
        return s
    }

    private func send(_ s: Store, _ path: String = "/x") async {
        s.current = RequestSpec(url: "http://127.0.0.1:9" + path)
        s.send()
        for _ in 0..<250 where s.isSending { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func env(_ s: Store, _ name: String, host: String, apiKey: String? = nil) -> UUID {
        var vars = [KeyValue(key: "baseUrl", value: "https://\(host)")]
        if let apiKey { vars.append(KeyValue(key: "apiKey", value: apiKey, secret: true)) }
        let e = EnvSet(name: name, vars: vars)
        s.envs.append(e)
        return e.id
    }

    private func e(_ s: Store, _ id: UUID) -> EnvSet { s.envs.first { $0.id == id }! }

    // MARK: - History per environment (checklist 1–8)

    func testHistoryIsScopedToActiveEnvironment() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com"), b = env(s, "B", host: "b.example.com")
        s.activeEnvID = a; await send(s, "/a")
        s.activeEnvID = b; await send(s, "/b")
        s.activeEnvID = nil; await send(s, "/none")

        s.activeEnvID = a
        XCTAssertEqual(s.envHistory.map(\.request.url), ["http://127.0.0.1:9/a"])
        s.activeEnvID = b
        XCTAssertEqual(s.envHistory.map(\.request.url), ["http://127.0.0.1:9/b"])
        s.activeEnvID = nil
        XCTAssertEqual(s.envHistory.map(\.request.url), ["http://127.0.0.1:9/none"])
    }

    func testSwitchingEnvironmentMidFlightKeepsHistoryWithSendingEnvironment() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com")
        s.activeEnvID = a
        s.current = RequestSpec(url: "http://127.0.0.1:9/inflight")
        s.send()
        s.activeEnvID = nil                                            // switched before the response arrives
        for _ in 0..<250 where s.isSending { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(s.envHistory.isEmpty)
        s.activeEnvID = a
        XCTAssertEqual(s.envHistory.map(\.request.url), ["http://127.0.0.1:9/inflight"])
    }

    func testClearOnlyClearsActiveEnvironment() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com"), b = env(s, "B", host: "b.example.com")
        s.activeEnvID = a; await send(s)
        s.activeEnvID = b; await send(s)
        s.activeEnvID = nil; await send(s)
        s.activeEnvID = a; s.clearHistory()
        XCTAssertTrue(s.envHistory.isEmpty)
        s.activeEnvID = b; XCTAssertEqual(s.envHistory.count, 1)
        s.activeEnvID = nil; XCTAssertEqual(s.envHistory.count, 1)
    }

    func testHistorySurvivesRestart() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com")
        s.activeEnvID = a; await send(s, "/kept")
        s.persist()
        let s2 = await freshStore()
        XCTAssertEqual(s2.activeEnvID, a)
        XCTAssertEqual(s2.envHistory.map(\.request.url), ["http://127.0.0.1:9/kept"])
    }

    func testPastedURLSwitchesEnvironmentAndHistoryFollows() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com"), b = env(s, "B", host: "127.0.0.1")
        s.activeEnvID = a
        s.current = RequestSpec(url: "http://127.0.0.1:9/pasted")
        s.urlChanged()
        XCTAssertEqual(s.activeEnvID, b)
        s.send()
        for _ in 0..<250 where s.isSending { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(s.envHistory.map(\.request.url), ["http://127.0.0.1:9/pasted"])
    }

    func testDeletingEnvironmentDropsItsHistory() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com"), b = env(s, "B", host: "b.example.com")
        s.activeEnvID = a; await send(s)
        s.activeEnvID = b; await send(s)
        s.deleteEnv(a)
        XCTAssertFalse(s.history.contains { $0.envID == a })
        XCTAssertEqual(s.activeEnvID, b)
        XCTAssertEqual(s.envHistory.count, 1)
    }

    func testOldHistoryShowsUnderNoEnvironment() async throws {
        let json = #"{"saved":[],"envs":[],"history":[{"request":{"url":"https://old.dev"},"status":200,"duration":0}]}"#
        try Data(json.utf8).write(to: Store.fileURL)
        let s = await freshStore()
        s.activeEnvID = nil
        XCTAssertEqual(s.envHistory.map(\.request.url), ["https://old.dev"])
    }

    func testHistoryRowRecordsKeyOnlyWithSeveralKeys() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com", apiKey: "AAAA-1111-aaaa")
        s.activeEnvID = a; await send(s)
        XCTAssertNil(s.envHistory.first?.keyName)                     // one key: no noise
        s.addKey(named: "Test", credentials: ["apiKey": "BBBB-2222-bbbb"], in: a)
        await send(s)
        XCTAssertEqual(s.envHistory.first?.keyName, "Test")
    }

    // MARK: - Keys in the environment (checklist 9–18, 20)

    func testSingleKeyEnvironmentHasNoKeys() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com", apiKey: "AAAA-1111-aaaa")
        XCTAssertTrue(e(s, a).keys.isEmpty)                            // toolbar/URL bar show no key UI (< 2 keys)
        XCTAssertEqual(e(s, a).secretNames, ["apiKey"])               // editor shows the Keys section
    }

    func testAddKeyKeepsCurrentValuesAndUsesNewOne() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com", apiKey: "AAAA-1111-aaaa")
        s.activeEnvID = a
        let k = s.addKey(named: "Test account", credentials: ["apiKey": "BBBB-2222-bbbb"], in: a)
        XCTAssertEqual(e(s, a).keys.map(\.name), ["Key 1", "Test account"])
        XCTAssertEqual(e(s, a).keys[0].credentials["apiKey"], "AAAA-1111-aaaa")
        XCTAssertEqual(e(s, a).keyInUse?.id, k?.id)
        XCTAssertEqual(s.activeVars["apiKey"], "BBBB-2222-bbbb")      // what gets sent
    }

    func testSwitchingKeysChangesWhatIsSent() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com", apiKey: "AAAA-1111-aaaa")
        s.activeEnvID = a
        s.addKey(named: "Test", credentials: ["apiKey": "BBBB-2222-bbbb"], in: a)
        s.useKey(e(s, a).keys[0].id)
        XCTAssertEqual(s.activeVars["apiKey"], "AAAA-1111-aaaa")
        XCTAssertEqual(e(s, a).keyInUse?.name, "Key 1")
    }

    func testPastingSecretValueEditsKeyInUse() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com", apiKey: "AAAA-1111-aaaa")
        s.activeEnvID = a
        s.addKey(named: "Test", credentials: ["apiKey": "BBBB-2222-bbbb"], in: a)
        var vars = e(s, a).vars
        vars[1].value = "CCCC-3333-cccc"                               // select-all + paste = one edit
        s.setVars(vars, in: a)
        s.useKey(e(s, a).keys[0].id); s.useKey(e(s, a).keys[1].id)  // switch away and back
        XCTAssertEqual(s.activeVars["apiKey"], "CCCC-3333-cccc")
        XCTAssertEqual(e(s, a).keys[0].credentials["apiKey"], "AAAA-1111-aaaa")
    }

    /// Backspacing to empty and retyping keeps editing the same key (was: drifted to "unsaved key").
    func testRetypingSecretValueEditsKeyInUse() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com", apiKey: "AAAA-1111-aaaa")
        s.activeEnvID = a
        s.addKey(named: "Test", credentials: ["apiKey": "BBBB-2222-bbbb"], in: a)
        for value in ["BBBB-2222-bbb", "", "C", "CC"] {                // keystrokes
            var vars = e(s, a).vars
            vars[1].value = value
            s.setVars(vars, in: a)
        }
        XCTAssertEqual(e(s, a).keyInUse?.name, "Test")
        XCTAssertEqual(e(s, a).keys[1].credentials["apiKey"], "CC")
        XCTAssertEqual(e(s, a).keys[0].credentials["apiKey"], "AAAA-1111-aaaa")   // other key untouched
    }

    func testDeletingKeysSwitchesThenBlanks() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com", apiKey: "AAAA-1111-aaaa")
        s.activeEnvID = a
        s.addKey(named: "Test", credentials: ["apiKey": "BBBB-2222-bbbb"], in: a)
        s.deleteKey(e(s, a).keyInUse!.id)
        XCTAssertEqual(e(s, a).keyInUse?.name, "Key 1")
        s.deleteKey(e(s, a).keyInUse!.id)
        XCTAssertTrue(e(s, a).keys.isEmpty)
        XCTAssertNil(s.activeVars["apiKey"].flatMap { $0.isEmpty ? nil : $0 })   // never sent again
    }

    func testPastedCurlWithNewTokenBecomesAnotherKey() async {
        let s = await freshStore()
        s.importCurl("curl 'https://api.example.com/v1/me' -H 'Authorization: Bearer sk_live_first_4f9a2c7e81b3'")
        s.makeReusable()
        s.importCurl("curl 'https://api.example.com/v1/me' -H 'Authorization: Bearer sk_live_second_77aa11bb22cc'")
        s.makeReusable()
        let env = s.activeEnv!
        XCTAssertEqual(env.keys.count, 2)
        XCTAssertEqual(env.keyInUse?.id, env.keys.last?.id)
        XCTAssertTrue(env.credentials.values.contains("sk_live_second_77aa11bb22cc"))
    }

    func testNewSecretVariableJoinsKeyInUseOnly() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com", apiKey: "AAAA-1111-aaaa")
        s.activeEnvID = a
        s.addKey(named: "Test", credentials: ["apiKey": "BBBB-2222-bbbb"], in: a)
        var vars = e(s, a).vars
        vars.append(KeyValue(key: "secret", value: "SSSS-4444-ssss", secret: true))
        s.setVars(vars, in: a)
        XCTAssertEqual(e(s, a).keys[1].credentials["secret"], "SSSS-4444-ssss")
        XCTAssertNil(e(s, a).keys[0].credentials["secret"])
    }

    func testRequestOwnAuthWinsOverEnvironmentKey() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com", apiKey: "AAAA-1111-aaaa")
        s.envs[s.envs.firstIndex { $0.id == a }!].auth = Auth(kind: .bearer, token: "{{apiKey}}")
        s.activeEnvID = a
        var spec = RequestSpec(url: "https://a.example.com/x")
        spec.auth = Auth(kind: .bearer, token: "own-token")
        XCTAssertEqual(s.effective(spec).auth.token, "own-token")
        XCTAssertEqual(s.effective(RequestSpec(url: "https://a.example.com/x")).auth.token, "{{apiKey}}")
    }

    func testKeysAndSecretsSurviveRestart() async {
        let s = await freshStore()
        let a = env(s, "A", host: "a.example.com", apiKey: "AAAA-1111-aaaa")
        s.activeEnvID = a
        s.addKey(named: "Test", credentials: ["apiKey": "BBBB-2222-bbbb"], in: a)
        s.persist()
        let raw = try? String(contentsOf: Store.fileURL, encoding: .utf8)
        XCTAssertFalse(raw?.contains("BBBB-2222-bbbb") ?? true)       // secrets not in state.json
        let s2 = await freshStore()
        let env = s2.envs.first { $0.id == a }!
        XCTAssertEqual(env.keys.map(\.name), ["Key 1", "Test"])
        XCTAssertEqual(env.keyInUse?.name, "Test")
        XCTAssertEqual(s2.activeVars["apiKey"], "BBBB-2222-bbbb")
    }
}
