import SwiftUI

/// Enough Markdown for a chat bubble: paragraphs, headings, lists, quotes,
/// fenced code, rules and tables. Bot replies are rendered; words the person
/// typed stay literal.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let content):
            Text(inline(content))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let content):
            Text(inline(content))
                .appFont(size: level <= 2 ? 17 : 15, weight: .semibold)
                .padding(.top, 2)
        case .bullet(let content):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if content.hasPrefix("[ ] ") || content.lowercased().hasPrefix("[x] ") {
                    Image(systemName: content.lowercased().hasPrefix("[x]") ? "checkmark.square" : "square")
                        .foregroundStyle(.secondary)
                    Text(inline(String(content.dropFirst(4)))).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("•").foregroundStyle(.secondary)
                    Text(inline(content)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 2)
        case .ordered(let mark, let content):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(mark).foregroundStyle(.secondary).monospacedDigit()
                Text(inline(content)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        case .quote(let content):
            Text(inline(content))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.hairline).frame(width: 2)
                }
        case .code(let content):
            // A horizontal ScrollView is greedy vertically: inside a transcript
            // it would swallow the page. Wrap instead.
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
        case .table(let content):
            let rows = content.split(separator: "\n").map { line in
                String(line).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                                .appFont(size: 12, weight: index == 0 ? .semibold : .regular)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 240, alignment: .leading)
                        }
                    }
                    if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 2)
        }
    }

    private func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case bullet(String)
    case ordered(String, String)
    case quote(String)
    case code(String)
    case table(String)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(heading.0, heading.1))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoted.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if let item = bulletContent(trimmed) {
                flushParagraph()
                blocks.append(.bullet(item))
                index += 1
                continue
            }

            if let item = orderedContent(trimmed) {
                flushParagraph()
                blocks.append(.ordered(item.0, item.1))
                index += 1
                continue
            }

            if trimmed.contains("|"), index + 1 < lines.count, isTableDelimiter(lines[index + 1]) {
                flushParagraph()
                var rows: [String] = []
                while index < lines.count, lines[index].contains("|") {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    if !isTableDelimiter(lines[index]) { rows.append(row) }
                    index += 1
                }
                blocks.append(.table(rows.joined(separator: "\n")))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks.isEmpty ? [.paragraph(text)] : blocks
    }

    private static func headingLevel(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletContent(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedContent(_ line: String) -> (String, String)? {
        var digits = ""
        var rest = Substring(line)
        while let first = rest.first, first.isNumber {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (digits + String(rest.prefix(1)), String(rest.dropFirst(2)))
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }
}
