import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()

    var body: some Scene {
        Window("Wisp", id: "main") {
            ContentView()
                .environment(store)
                .tint(Theme.accent)
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: Updater.shared)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Request") { store.newRequest() }.keyboardShortcut("n")
                Divider()
                Button("Import…") { store.sheet = .importer }.keyboardShortcut("o")
                Button("Export Docs as Markdown…") { store.exportDocs() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Request") {
                Button("Send") { store.send() }.keyboardShortcut(.return)
                Button("Cancel") { store.cancel() }.keyboardShortcut(".").disabled(!store.isSending)
                Button("Save") { store.save() }.keyboardShortcut("s")
                Divider()
                Button("Copy as cURL") { store.copyCurl() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Import cURL from Clipboard") { store.importCurlFromClipboard() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Generate Code…") { store.sheet = .code }.keyboardShortcut("c", modifiers: [.command, .option])
                Button("GraphQL Query Builder…") {
                    if store.current.bodyKind != .graphql { store.useGraphQL(query: "", variables: "") }
                    store.sheet = .graphQLBuilder
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Toggle("Follow Redirects", isOn: Binding(get: { store.followRedirects }, set: { store.followRedirects = $0 }))
                Button("Environments…") { store.sheet = .environments }.keyboardShortcut("e", modifiers: [.command, .option])
            }
        }
    }
}
