import CMarkGFM
import Foundation

enum MarkdownRenderer {
    struct Result {
        let html: String
        let containsMath: Bool
    }

    private static let registerExtensions: Void = {
        cmark_gfm_core_extensions_ensure_registered()
    }()

    static func makeParser() -> UnsafeMutablePointer<cmark_parser>? {
        _ = registerExtensions
        guard let parser = cmark_parser_new(CMARK_OPT_FOOTNOTES | CMARK_OPT_VALIDATE_UTF8) else { return nil }
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            if let syntax = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntax)
            }
        }
        return parser
    }

    static func render(_ markdown: String) -> Result? {
        guard let parser = makeParser() else { return nil }
        defer { cmark_parser_free(parser) }
        let protected = MarkdownMath.protect(markdown)
        cmark_parser_feed(parser, protected.text, protected.text.utf8.count)
        guard let root = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(root) }
        showRawHTMLAsText(in: root)
        guard let rendered = cmark_render_html(root, CMARK_OPT_FOOTNOTES | CMARK_OPT_HARDBREAKS, nil) else { return nil }
        defer { free(rendered) }
        let html = String(cString: rendered)
        return Result(
            html: protected.markedLineBreaks ? MarkdownMath.removeLineBreakMarkers(from: html) : html,
            containsMath: protected.containsMath
        )
    }

    private static func showRawHTMLAsText(in root: UnsafeMutablePointer<cmark_node>) {
        guard let iterator = cmark_iter_new(root) else { return }
        var nodes: [UnsafeMutablePointer<cmark_node>] = []
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) else { continue }
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_HTML_BLOCK || type == CMARK_NODE_HTML_INLINE { nodes.append(node) }
        }
        cmark_iter_free(iterator)
        for node in nodes {
            let type = cmark_node_get_type(node) == CMARK_NODE_HTML_BLOCK ? CMARK_NODE_CODE_BLOCK : CMARK_NODE_TEXT
            guard let literal = cmark_node_get_literal(node), let replacement = cmark_node_new(type) else { continue }
            cmark_node_set_literal(replacement, literal)
            if cmark_node_replace(node, replacement) == 1 { cmark_node_free(node) }
            else { cmark_node_free(replacement) }
        }
    }
}
