import SwiftUI
import WebKit

/// HTML responses: a readable "Page" summary by default, a rendered preview, or the source.
struct HTMLResponseView: View {
    enum Mode: String, CaseIterable { case page = "Page", preview = "Preview", source = "Source" }

    @Environment(Store.self) private var store
    let response: ResponseData
    @State private var mode: Mode = .page

    var body: some View {
        let summary = HTMLSummary.parse(response.text, base: response.url)
        VStack(alignment: .leading, spacing: 0) {
            ChoiceChips(items: Mode.allCases, selection: $mode, title: \.rawValue)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            switch mode {
            case .page: HTMLPageView(response: response, summary: summary)
            case .preview: HTMLPreview(html: response.text, baseURL: response.url)
            case .source:
                CodeTextView(text: .constant(response.text), editable: false, highlightHTML: true)
                    .padding(.horizontal, 6)
            }
        }
        #if DEBUG
        .onAppear { if let m = ProcessInfo.processInfo.environment["WISP_DEMO_HTMLMODE"].flatMap(Mode.init) { mode = m } }
        #endif
    }
}

private struct HTMLPageView: View {
    @Environment(Store.self) private var store
    let response: ResponseData
    let summary: HTMLSummary

    var body: some View {
        let host = (response.redirects.first?.from ?? response.url)?.host?.lowercased()
        let knownBase = store.envs.first { $0.host != nil && $0.host == host }?.vars.first { $0.key == "baseUrl" }?.value
        let hint = HTMLHint.make(for: response, summary: summary, knownBase: knownBase)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Why am I looking at a web page?
                VStack(alignment: .leading, spacing: 6) {
                    Label(hint.title, systemImage: "globe").font(.system(size: 13, weight: .semibold))
                    Text(hint.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.accent.opacity(0.08)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.title ?? "Untitled page").font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                    if let url = response.url {
                        Text(url.absoluteString).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    if let d = summary.description, !d.isEmpty {
                        Text(d).font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.top, 2).textSelection(.enabled)
                    }
                }

                if !summary.headings.isEmpty {
                    section("Headings") {
                        ForEach(summary.headings, id: \.self) { Text($0).font(.system(size: 12.5)) }
                    }
                }
                if !summary.text.isEmpty {
                    section("Text") {
                        Text(summary.text).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(14).textSelection(.enabled)
                    }
                }
                if !summary.links.isEmpty {
                    section("Links") {
                        ForEach(summary.links, id: \.self) { link in
                            Button { NSWorkspace.shared.open(link.url) } label: {
                                HStack(spacing: 6) {
                                    Text(link.title).foregroundStyle(Theme.accent).lineLimit(1)
                                    Text(link.url.host ?? "").foregroundStyle(.tertiary).lineLimit(1)
                                }
                                .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .help(link.url.absoluteString)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            content()
        }
    }
}

/// Rendered page. Created only when the Preview tab is opened; JavaScript off, nothing persisted,
/// links open in the default browser.
private struct HTMLPreview: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: baseURL)
        context.coordinator.loaded = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = ""
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
