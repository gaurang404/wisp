import SwiftUI

/// Insights as quiet inline text — warnings in orange, copyable ones clickable.
struct InsightLine: View {
    @Environment(Store.self) private var store
    let insights: [ResponseInsight]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(insights) { i in
                let label = HStack(spacing: 4) {
                    Image(systemName: i.icon).imageScale(.small)
                    Text(i.text).lineLimit(1)
                    // Show the value itself (e.g. a request ID) so it can be selected.
                    if let v = i.copyValue {
                        Text(v).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 140)
                        Image(systemName: "doc.on.doc").font(.system(size: 9))
                    }
                }
                .foregroundStyle(i.level == .warning ? Color.orange : .secondary)
                .fixedSize(horizontal: i.copyValue == nil, vertical: false)
                .help(i.help)
                if let v = i.copyValue {
                    Button { store.copy(v, label: "Copied \(i.text)") } label: { label }.buttonStyle(.plain)
                } else {
                    label
                }
            }
        }
    }
}
