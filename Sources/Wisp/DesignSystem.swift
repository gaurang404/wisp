import SwiftUI

// Small set of shared building blocks so every pane looks like one app.

enum Theme {
    static let radius: CGFloat = 8
    static let fill = Color.primary.opacity(0.04)
    static let stroke = Color.primary.opacity(0.06)
    static let mono = Font.system(size: 12.5, design: .monospaced)
    /// Wisp's signature colour — the violet of the app icon, tuned for light and dark.
    static let accent = Color(nsColor: NSColor(name: "WispAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x8E / 255, green: 0x7C / 255, blue: 0xFF / 255, alpha: 1)
            : NSColor(srgbRed: 0x5B / 255, green: 0x45 / 255, blue: 0xE0 / 255, alpha: 1)
    })
}

/// Soft rounded panel used behind editors, tables and code.
struct Surface: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.stroke, lineWidth: focused ? 1.5 : 1)
            )
    }
}

extension View {
    func surface(focused: Bool = false) -> some View { modifier(Surface(focused: focused)) }
}

/// Underlined text tabs with optional count badge or dot.
struct TabBar<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let title: (T) -> String
    /// nil → nothing, "" → dot, otherwise a count badge.
    var badge: (T) -> String? = { _ in nil }
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 20) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = item }
                } label: {
                    HStack(spacing: 5) {
                        Text(title(item)).fontWeight(on ? .semibold : .regular)
                        if let b = badge(item) {
                            if b.isEmpty {
                                Circle().fill(Theme.accent).frame(width: 5, height: 5)
                            } else {
                                Text(b)
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(on ? Theme.accent.opacity(0.2) : Color.primary.opacity(0.08)))
                            }
                        }
                    }
                    .foregroundStyle(on ? .primary : .secondary)
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) {
                        if on {
                            Capsule().fill(Theme.accent).frame(height: 2)
                                .matchedGeometryEffect(id: "underline", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
        .fixedSize()
    }
}

/// Compact pill selector — replaces wide segmented controls.
struct ChoiceChips<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let title: (T) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                Button { selection = item } label: {
                    Text(title(item))
                        .lineLimit(1)
                        .fixedSize()
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.accent : .secondary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Theme.accent.opacity(0.16) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fill))
        .overlay(Capsule().strokeBorder(Theme.stroke))
    }
}

/// Text field matching the soft surfaces (replaces .roundedBorder).
struct SoftFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .surface()
    }
}

extension TextFieldStyle where Self == SoftFieldStyle {
    static var soft: SoftFieldStyle { SoftFieldStyle() }
}

/// "now", "42s", "5m", "3h", "2d"
func shortAgo(_ date: Date, now: Date = .now) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    switch s {
    case ..<5: return "now"
    case ..<60: return "\(s)s"
    case ..<3600: return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h"
    default: return "\(s / 86400)d"
    }
}

/// Dropdown styled like the soft fields.
struct SoftMenu<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let title: (T) -> String

    var body: some View {
        Menu {
            ForEach(items, id: \.self) { item in Button(title(item)) { selection = item } }
        } label: {
            HStack(spacing: 6) {
                Text(title(selection)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .surface()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Small rounded "chip" for metadata (time, size).
struct Chip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).imageScale(.small)
            Text(text).monospacedDigit().lineLimit(1)
        }
        .fixedSize()
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Theme.fill))
    }
}

struct Keycap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.stroke))
    }
}

struct ShortcutHint: View {
    let keys: [String]
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { Keycap(key: $0) }
            Text(label).foregroundStyle(.secondary).padding(.leading, 4)
        }
        .font(.callout)
    }
}

/// Icon-only borderless button with hover highlight.
struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover ? .primary : .secondary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.fill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct MethodBadge: View {
    let method: HTTPMethod
    var body: some View {
        Text(method.short)
            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
            .foregroundStyle(method.color)
            .frame(width: 34, alignment: .leading)
    }
}

extension HTTPMethod {
    var short: String {
        switch self {
        case .DELETE: "DEL"
        case .OPTIONS: "OPT"
        case .PATCH: "PTCH"
        default: rawValue
        }
    }
}
