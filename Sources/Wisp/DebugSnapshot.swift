#if DEBUG
import SwiftUI

/// Dev-only UI smoke test: WISP_DEMO_CURL='curl …' WISP_SNAPSHOT=/tmp/x.png swift run
/// Imports the command, sends it, writes a PNG of the window and quits.
extension View {
    func debugSnapshotHook(_ store: Store) -> some View {
        task {
            let env = ProcessInfo.processInfo.environment
            guard let out = env["WISP_SNAPSHOT"] else { return }
            if env["WISP_LIGHT"] != nil { NSApp.appearance = NSAppearance(named: .aqua) }
            if env["WISP_DARK"] != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if let size = env["WISP_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
               let w = NSApp.windows.first(where: { $0.isVisible }) {
                w.setFrame(NSRect(x: 80, y: 80, width: size[0], height: size[1]), display: true)
            }
            if let path = env["WISP_DEMO_IMPORT"], let data = FileManager.default.contents(atPath: path) {
                store.importData(data)
            }
            if let u = env["WISP_DEMO_IMPORT_URL"], let error = await store.importFromURL(u) { print("IMPORT ERROR:", error) }
            if let curl = env["WISP_DEMO_CURL"] {
                store.importCurl(curl)
                if let name = env["WISP_DEMO_NAME"] { store.current.name = name }
                if let folder = env["WISP_DEMO_FOLDER"] { store.current.folder = folder }
                if env["WISP_DEMO_SAVE"] != nil { store.save() }
                store.send()
            }
            if let kv = env["WISP_DEMO_VAR"]?.split(separator: "=", maxSplits: 1), kv.count == 2 {
                store.setVariable(String(kv[0]), String(kv[1]))
            }
            if let name = env["WISP_DEMO_OPEN"], let r = store.saved.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                store.open(r)
                try? await Task.sleep(for: .seconds(0.3))
                if env["WISP_DEMO_NOSEND"] == nil { store.send() }
            }
            if env["WISP_DEMO_GQL"] != nil { store.tryGraphQLDemo() }
            if let url = env["WISP_DEMO_URL"] { store.newRequest(); store.current.url = url }
            if env["WISP_DEMO_REUSE"] != nil { store.makeReusable() }
            if let url = env["WISP_DEMO_KEYS_URL"] {   // two named keys for one API (needs WISP_DATA_DIR)
                for name in ["personal", "team"] {
                    store.importCurl("curl '\(url)' -H 'Authorization: Bearer sk_demo_\(name)_4f9a2c7e81b3'")
                    store.makeReusable()
                }
                if let i = store.envs.firstIndex(where: { $0.id == store.activeEnvID }), store.envs[i].keys.count == 2 {
                    store.envs[i].keys[0].name = "Personal"
                    store.envs[i].keys[1].name = "Team"
                }
            }
            if let url = env["WISP_DEMO_URL3"] {   // keeps the active environment
                store.newRequest()
                store.current.url = url
                try? await Task.sleep(for: .seconds(0.3))
                store.send()
            }
            if let url = env["WISP_DEMO_URL2"] {
                store.activeEnvID = nil
                store.newRequest()
                store.current.url = url
                try? await Task.sleep(for: .seconds(0.3))   // let the URL bar react (environment by host)
                store.send()
            }
            if let url = env["WISP_DEMO_GQL_URL"] {
                store.newRequest()
                store.current.url = url
                store.useGraphQL(query: "", variables: "")
            }
            if let tab = env["WISP_DEMO_TAB"] {
                try? await Task.sleep(for: .seconds(0.3))
                NotificationCenter.default.post(name: .wispDemoTab, object: tab)
            }
            switch env["WISP_DEMO_SHEET"] {
            case "code": store.sheet = .code
            case "import": store.sheet = .importer
            case "jwt": store.sheet = .jwt(env["WISP_DEMO_JWT"] ?? "")
            case "gql": store.sheet = .graphQLBuilder
            case "keys": store.sheet = .keys
            default: break
            }
            try? await Task.sleep(for: .seconds(Double(env["WISP_SNAPSHOT_DELAY"] ?? "4") ?? 4))
            if env["WISP_DEMO_NEXT"] != nil {
                store.loadNextPage()
                try? await Task.sleep(for: .seconds(3))
            }
            if let f = env["WISP_DEMO_FILTER"] { NotificationCenter.default.post(name: .wispDemoFilter, object: f) }
            try? await Task.sleep(for: .seconds(0.5))
            let win = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil })
            if let sheet = win?.attachedSheet?.contentView?.superview,
               let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) {
                sheet.cacheDisplay(in: sheet.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "-sheet.png")))
            }
            guard let view = win?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
    }
}

extension Notification.Name {
    static let wispDemoFilter = Notification.Name("wispDemoFilter")
    static let wispDemoTab = Notification.Name("wispDemoTab")
}
#endif
