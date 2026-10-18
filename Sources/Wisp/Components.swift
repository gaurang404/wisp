import SwiftUI

/// Plain monospaced NSTextView: no smart quotes (safe for JSON), native ⌘F find bar, fast on large text.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var editable = true
    var highlightJSON = false
    var highlightGraphQL = false
    var highlightHTML = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = editable
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tv.textColor = .textColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        set(tv, text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = editable
        if tv.string != text { set(tv, text) }
    }

    private func set(_ tv: NSTextView, _ s: String) {
        tv.string = s
        if let storage = tv.textStorage {
            if highlightJSON { JSONFormat.highlight(storage) }
            if highlightGraphQL { GraphQL.highlight(storage) }
            if highlightHTML { HTMLHighlight.highlight(storage) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        init(_ parent: CodeTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            if let storage = tv.textStorage, storage.length < 200_000 {
                if parent.highlightJSON { JSONFormat.highlight(storage) }
                if parent.highlightGraphQL { GraphQL.highlight(storage) }
            }
        }
    }
}

/// Table-style key/value editor. Always keeps one empty trailing row, so typing into it just grows the table.
/// Uses id-based bindings so deleting rows never crashes.
struct KeyValueEditor: View {
    @Binding var items: [KeyValue]
    var keyPlaceholder = "Key"
    var valuePlaceholder = "Value"
    /// Shows a lock per row; locked values are masked and stored in the Keychain.
    var allowSecrets = false
    @State private var hovered: UUID?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().opacity(0.6) }
                    row(item, isTrailing: index == items.count - 1 && item.key.isEmpty && item.value.isEmpty)
                }
            }
            .surface()
        }
        .onAppear(perform: normalize)
        .onChange(of: items) { normalize() }
    }

    private func row(_ item: KeyValue, isTrailing: Bool) -> some View {
        HStack(spacing: 0) {
            Toggle("", isOn: binding(item.id).enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .opacity(isTrailing ? 0 : 1)
                .frame(width: 30)
            TextField(keyPlaceholder, text: binding(item.id).key)
                .frame(maxWidth: .infinity)
            Rectangle().fill(Theme.stroke).frame(width: 1).padding(.vertical, 6)
            Group {
                if item.secret {
                    SecureField(valuePlaceholder, text: binding(item.id).value)
                } else {
                    TextField(valuePlaceholder, text: binding(item.id).value)
                }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity)
            if allowSecrets, !isTrailing {
                Button { binding(item.id).wrappedValue.secret.toggle() } label: {
                    Image(systemName: item.secret ? "lock.fill" : "lock.open")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item.secret ? Theme.accent : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(item.secret || hovered == item.id ? 1 : 0.35)
                .help(item.secret ? "Secret — stored in the macOS Keychain. Click to make it plain." : "Mark as secret (stored in the Keychain, masked here)")
            }
            Button { items.removeAll { $0.id == item.id } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovered == item.id && !isTrailing ? 1 : 0)
            .help("Remove")
        }
        .textFieldStyle(.plain)
        .font(Theme.mono)
        .frame(height: 32)
        .opacity(item.enabled || isTrailing ? 1 : 0.45)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
    }

    private func normalize() {
        if let last = items.last, last.key.isEmpty, last.value.isEmpty { return }
        items.append(KeyValue())
    }

    private func binding(_ id: UUID) -> Binding<KeyValue> {
        Binding(
            get: { items.first { $0.id == id } ?? KeyValue(id: id) },
            set: { v in if let i = items.firstIndex(where: { $0.id == id }) { items[i] = v } }
        )
    }
}

typealias MethodLabel = MethodBadge

extension HTTPMethod {
    var color: Color {
        switch self {
        case .GET: .green
        case .POST: .orange
        case .PUT: .blue
        case .PATCH: .purple
        case .DELETE: .red
        case .HEAD, .OPTIONS: .gray
        }
    }
}

func statusColor(_ status: Int?) -> Color {
    switch status ?? 0 {
    case 200..<300: .green
    case 300..<400: .blue
    case 400..<500: .orange
    case 500...: .red
    default: .gray
    }
}

func reasonPhrase(_ status: Int) -> String {
    let common: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
        301: "Moved Permanently", 302: "Found", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
        409: "Conflict", 415: "Unsupported Media Type", 422: "Unprocessable Content", 429: "Too Many Requests",
        500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
    ]
    return common[status] ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
}
