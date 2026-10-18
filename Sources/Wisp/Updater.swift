import Combine
import Sparkle
import SwiftUI

/// In-app updates via Sparkle. Feed: SUFeedURL (wisp.build/appcast.xml); updates are EdDSA-signed (SUPublicEDKey).
/// Only active in a release bundle that has a public key — `swift run` and tests never touch the network for this.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var canCheck = false
    private let controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?

    var isAvailable: Bool { controller != nil }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let configured = Bundle.main.bundleURL.pathExtension == "app"
            && !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
            && !((info["SUFeedURL"] as? String) ?? "").isEmpty
        guard configured else { controller = nil; return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        observation = c.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

/// "Check for Updates…" for the app menu.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if updater.isAvailable {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
        }
    }
}
