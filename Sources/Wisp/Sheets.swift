import SwiftUI
import UniformTypeIdentifiers

// MARK: - Code export

struct CodeSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("codeLanguage") private var language: CodeLanguage = .curl

    var body: some View {
        let code = (try? store.builtRequest()).map { CodeGen.generate($0, language: language) }
            ?? "// Fix the request first: the URL could not be built."
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Language", selection: $language) {
                    ForEach(CodeLanguage.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Spacer()
                Button("Copy") { store.copy(code, label: "Copied \(language.rawValue)") }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CodeTextView(text: .constant(code), editable: false)
                .surface()
            if store.current.auth.kind == .oauth2, store.currentToken == nil {
                Text("No OAuth token yet — send the request once to include it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }
        .padding(16)
        .frame(width: 680, height: 460)
    }
}

// MARK: - Import

struct ImportSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var pasted = ""
    @State private var busy = false
    @State private var urlError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import").font(.title2.bold())
            Text("OpenAPI 3 · Swagger 2 (JSON or YAML) · Postman · Insomnia · HAR · cURL. Requests land in a folder, and variables like {{baseUrl}} go into a matching environment.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("From a file") {
                HStack {
                    Text("…or drop a file anywhere on the Wisp window.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose File…") { chooseFile() }
                }
                .padding(4)
            }
            GroupBox("From API docs or a spec URL") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("https://petstore3.swagger.io  ·  …/openapi.json", text: $urlString)
                            .textFieldStyle(.soft)
                            .onSubmit(importURL)
                        Button("Import", action: importURL).disabled(urlString.isEmpty || busy)
                    }
                    if let urlError {
                        Text(urlError).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Paste a docs page — Wisp finds the OpenAPI/Swagger spec behind it and imports every endpoint, with an environment for the API.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(4)
            }
            GroupBox("Paste") {
                VStack(alignment: .trailing) {
                    CodeTextView(text: $pasted).frame(height: 110)
                        .surface()
                    Button("Import Pasted") { store.importData(Data(pasted.utf8)); dismiss() }
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(4)
            }
            HStack {
                if busy { ProgressView().controlSize(.small); Text(store.status ?? "Working…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .yaml, .plainText, UTType(filenameExtension: "har") ?? .json, .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            store.importData(data)
            dismiss()
        }
    }

    private func importURL() {
        busy = true
        urlError = nil
        Task {
            let error = await store.importFromURL(urlString)
            busy = false
            if let error { urlError = error } else { dismiss() }
        }
    }
}

// MARK: - JWT inspector

struct JWTSheet: View {
    let token: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let info = JWT.decode(token) {
                HStack(spacing: 14) {
                    Label(info.isExpired ? "Expired" : "Valid", systemImage: info.isExpired ? "xmark.seal" : "checkmark.seal")
                        .foregroundStyle(info.isExpired ? .red : .green)
                    if let exp = info.expiresAt {
                        Text("expires \(exp.formatted(date: .abbreviated, time: .standard)) (\(exp, style: .relative))")
                    }
                    if let sub = info.subject { Text("sub: \(sub)").lineLimit(1) }
                    if let iss = info.issuer { Text("iss: \(iss)").lineLimit(1) }
                }
                .font(.callout)
                Text("Header").font(.headline)
                CodeTextView(text: .constant(info.header), editable: false, highlightJSON: true)
                    .frame(height: 90)
                    .surface()
                Text("Payload").font(.headline)
                CodeTextView(text: .constant(info.payload), editable: false, highlightJSON: true)
                    .surface()
                Text("Decoded locally. The signature is not verified.").font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("Not a JWT", systemImage: "questionmark.diamond")
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }
        .padding(16)
        .frame(width: 620, height: 520)
    }
}

// MARK: - Markdown

/// Small block-level Markdown renderer: headings, fenced code, tables, lists, quotes, inline styles.
struct MarkdownView: View {
    let text: String

    private enum Block: Hashable {
        case heading(Int, String), code(String), table(String), bullet(String), quote(String), paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]?
        var table: [String] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
            if !table.isEmpty { out.append(.table(table.joined(separator: "\n"))); table = [] }
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil }
                else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.hasPrefix("|") {
                if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
                if !line.contains("---") { table.append(line) }
                continue
            }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush(); out.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix(">") {
                flush(); out.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                if !table.isEmpty { flush() }
                para.append(line)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let level, let s):
                        inline(s).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                            .padding(.top, 4)
                    case .code(let s):
                        Text(s).font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    case .table(let s):
                        Text(s.replacingOccurrences(of: "|", with: " │ "))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .bullet(let s):
                        HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(s) }
                    case .quote(let s):
                        inline(s).foregroundStyle(.secondary).padding(.leading, 10)
                            .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
                    case .paragraph(let s):
                        inline(s)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}
