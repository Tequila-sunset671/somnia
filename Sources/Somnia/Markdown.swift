import SwiftUI

// MARK: - Lightweight block-level markdown renderer with clickable [[wiki-links]]

enum MDBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String)
    case quote(String)
    case code(String)
    case rule
}

struct MarkdownView: View {
    let text: String
    @EnvironmentObject var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MarkdownView.parse(text).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func render(_ b: MDBlock) -> some View {
        let p = theme.palette
        switch b {
        case .heading(let lvl, let t):
            Text(inline(t))
                .font(.system(size: lvl == 1 ? 22 : lvl == 2 ? 17 : 14.5, weight: .semibold))
                .padding(.top, lvl == 1 ? 2 : 0)
        case .paragraph(let t):
            Text(inline(t)).font(.system(size: 13)).foregroundStyle(p.text)
        case .bullet(let t):
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(p.faint)
                Text(inline(t)).font(.system(size: 13)).foregroundStyle(p.text)
            }
        case .quote(let t):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(theme.accent.opacity(0.5)).frame(width: 3)
                Text(inline(t)).font(.system(size: 13)).foregroundStyle(p.dim)
            }
        case .code(let t):
            Text(t).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.dim)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(p.surface2))
        case .rule:
            Divider().overlay(p.border)
        }
    }

    // MARK: Inline → AttributedString (emphasis, code, links, wiki-links)

    private func inline(_ s: String) -> AttributedString {
        let replaced = MarkdownView.replaceWikiLinks(s)
        var attr = (try? AttributedString(
            markdown: replaced,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        for run in attr.runs where run.link != nil {
            attr[run.range].foregroundColor = theme.accent
            attr[run.range].underlineStyle = .single
        }
        return attr
    }

    /// `[[Title]]` → `[Title](somnia://note/Title)`
    static func replaceWikiLinks(_ s: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: "\\[\\[([^\\]]+)\\]\\]") else { return s }
        let ns = NSMutableString(string: s)
        let matches = rx.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
        for m in matches.reversed() {
            let title = (s as NSString).substring(with: m.range(at: 1))
            let enc = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            ns.replaceCharacters(in: m.range, with: "[\(title)](somnia://note/\(enc))")
        }
        return ns as String
    }

    // MARK: Block parsing

    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var codeBuf: [String]? = nil
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if let buf = codeBuf { blocks.append(.code(buf.joined(separator: "\n"))); codeBuf = nil }
                else { codeBuf = [] }
                continue
            }
            if codeBuf != nil { codeBuf?.append(line); continue }

            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t == "---" || t == "***" { blocks.append(.rule) }
            else if t.hasPrefix("### ") { blocks.append(.heading(3, String(t.dropFirst(4)))) }
            else if t.hasPrefix("## ")  { blocks.append(.heading(2, String(t.dropFirst(3)))) }
            else if t.hasPrefix("# ")   { blocks.append(.heading(1, String(t.dropFirst(2)))) }
            else if t.hasPrefix("> ")   { blocks.append(.quote(String(t.dropFirst(2)))) }
            else if t.hasPrefix("- ") || t.hasPrefix("* ") { blocks.append(.bullet(String(t.dropFirst(2)))) }
            else { blocks.append(.paragraph(t)) }
        }
        if let buf = codeBuf { blocks.append(.code(buf.joined(separator: "\n"))) }
        return blocks
    }
}
