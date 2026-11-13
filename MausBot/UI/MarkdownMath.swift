import CMarkGFM
import Foundation

// Adapted from MiaoYan's MIT-licensed Business/Markdown.swift.
enum MarkdownMath {
    private struct Delimiter {
        let open: [Unicode.Scalar]
        let close: [Unicode.Scalar]
    }

    private static let delimiters = [
        Delimiter(open: Array("$$".unicodeScalars), close: Array("$$".unicodeScalars)),
        Delimiter(open: Array("$".unicodeScalars), close: Array("$".unicodeScalars)),
        Delimiter(open: Array("\\(".unicodeScalars), close: Array("\\)".unicodeScalars)),
        Delimiter(open: Array("\\[".unicodeScalars), close: Array("\\]".unicodeScalars)),
    ]
    private static let lineBreakMarker: Unicode.Scalar = "\u{E000}"

    static func protect(_ markdown: String) -> (text: String, containsMath: Bool, markedLineBreaks: Bool) {
        guard markdown.contains("$") || markdown.contains("\\(") || markdown.contains("\\[") else {
            return (markdown, false, false)
        }
        let scalars = Array(markdown.unicodeScalars)
        let mask = codeMask(in: scalars, markdown: markdown)
        let markLineBreaks = !scalars.contains(lineBreakMarker)
        var output = ""
        output.reserveCapacity(markdown.utf8.count)
        var foundMath = false
        var index = 0
        while index < scalars.count {
            guard !mask[index], let delimiter = delimiters.first(where: {
                matches($0.open, at: index, in: scalars, mask: mask)
                    && !isEscaped(at: index, in: scalars)
                    && !isCurrency($0.open, at: index, in: scalars)
            }), let end = closingDelimiter(delimiter.close, from: index + delimiter.open.count, in: scalars, mask: mask) else {
                output.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }
            foundMath = true
            for scalar in delimiter.open { appendEncoded(scalar, to: &output) }
            var previous: Unicode.Scalar?
            for scalar in scalars[(index + delimiter.open.count)..<end] {
                if markLineBreaks, isLineBreak(scalar), !(previous.map(isLineBreak) ?? false) {
                    output.unicodeScalars.append(lineBreakMarker)
                }
                appendEncoded(scalar, to: &output)
                previous = scalar
            }
            for scalar in delimiter.close { appendEncoded(scalar, to: &output) }
            index = end + delimiter.close.count
        }
        return (output, foundMath, markLineBreaks)
    }

    static func removeLineBreakMarkers(from html: String) -> String {
        let marker = String(lineBreakMarker)
        return html.replacingOccurrences(of: marker + "<br />", with: "").replacingOccurrences(of: marker, with: "")
    }

    private static func codeMask(in scalars: [Unicode.Scalar], markdown: String) -> [Bool] {
        var mask = Array(repeating: false, count: scalars.count)
        if let parser = MarkdownRenderer.makeParser() {
            defer { cmark_parser_free(parser) }
            cmark_parser_feed(parser, markdown, markdown.utf8.count)
            if let root = cmark_parser_finish(parser) {
                defer { cmark_node_free(root) }
                if let iterator = cmark_iter_new(root) {
                    defer { cmark_iter_free(iterator) }
                    var lineStarts = [0]
                    var i = 0
                    while i < scalars.count {
                        if scalars[i].value == 13 {
                            if i + 1 < scalars.count, scalars[i + 1].value == 10 { i += 1 }
                            lineStarts.append(i + 1)
                        } else if scalars[i].value == 10 {
                            lineStarts.append(i + 1)
                        }
                        i += 1
                    }
                    while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
                        guard let node = cmark_iter_get_node(iterator), cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK else { continue }
                        let startLine = max(Int(cmark_node_get_start_line(node)) - 1, 0)
                        let endLine = max(Int(cmark_node_get_end_line(node)), 0)
                        guard startLine < lineStarts.count else { continue }
                        let start = lineStarts[startLine]
                        let end = endLine < lineStarts.count ? lineStarts[endLine] : scalars.count
                        if start < end { for position in start..<end { mask[position] = true } }
                    }
                }
            }
        }
        var index = 0
        while index < scalars.count {
            guard !mask[index], scalars[index].value == 96, !isEscaped(at: index, in: scalars) else {
                index += 1
                continue
            }
            let length = runLength(of: 96, from: index, in: scalars)
            var cursor = index + length
            var closing: Int?
            while cursor < scalars.count, !mask[cursor] {
                if scalars[cursor].value == 96 {
                    let count = runLength(of: 96, from: cursor, in: scalars)
                    if count == length { closing = cursor; break }
                    cursor += count
                } else {
                    cursor += 1
                }
            }
            if let closing {
                for position in index..<(closing + length) { mask[position] = true }
                index = closing + length
            } else {
                index += length
            }
        }
        return mask
    }

    private static func closingDelimiter(_ delimiter: [Unicode.Scalar], from start: Int, in scalars: [Unicode.Scalar], mask: [Bool]) -> Int? {
        var index = start
        var braces = 0
        while index < scalars.count {
            if mask[index] { return nil }
            if braces <= 0, matches(delimiter, at: index, in: scalars, mask: mask), !isCurrency(delimiter, at: index, in: scalars) {
                return index
            }
            switch scalars[index].value {
            case 92: index += min(2, scalars.count - index)
            case 123: braces += 1; index += 1
            case 125: braces -= 1; index += 1
            default: index += 1
            }
        }
        return nil
    }

    private static func matches(_ delimiter: [Unicode.Scalar], at index: Int, in scalars: [Unicode.Scalar], mask: [Bool]) -> Bool {
        guard index + delimiter.count <= scalars.count else { return false }
        return delimiter.indices.allSatisfy { !mask[index + $0] && scalars[index + $0] == delimiter[$0] }
    }

    private static func isEscaped(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        var cursor = index
        while cursor > 0, scalars[cursor - 1].value == 92 { cursor -= 1 }
        return (index - cursor) % 2 == 1
    }

    private static func isCurrency(_ delimiter: [Unicode.Scalar], at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        guard delimiter.count == 1, delimiter[0].value == 36 else { return false }
        var cursor = index + 1
        let start = cursor
        while cursor < scalars.count, (48...57).contains(scalars[cursor].value) { cursor += 1 }
        guard cursor > start else { return false }
        if cursor < scalars.count, scalars[cursor].value == 46 || scalars[cursor].value == 44 {
            cursor += 1
            let fractionalStart = cursor
            while cursor < scalars.count, (48...57).contains(scalars[cursor].value) { cursor += 1 }
            if cursor == fractionalStart { cursor -= 1 }
        }
        guard cursor < scalars.count else { return true }
        let next = scalars[cursor].value
        let alphaNumeric = (48...57).contains(next) || (65...90).contains(next) || (97...122).contains(next)
        let mathContinuation: Set<UInt32> = [36, 40, 42, 43, 45, 47, 60, 61, 62, 92, 94, 95]
        return !alphaNumeric && !mathContinuation.contains(next)
    }

    private static func runLength(of value: UInt32, from start: Int, in scalars: [Unicode.Scalar]) -> Int {
        var end = start
        while end < scalars.count, scalars[end].value == value { end += 1 }
        return end - start
    }

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 10 || scalar.value == 13
    }

    private static func appendEncoded(_ scalar: Unicode.Scalar, to text: inout String) {
        if isLineBreak(scalar) { text.unicodeScalars.append(scalar) }
        else { text.append("&#\(scalar.value);") }
    }
}
