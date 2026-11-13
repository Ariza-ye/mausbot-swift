import AppKit
import SwiftUI
import WebKit

struct MarkdownText: NSViewRepresentable {
    let text: String
    @AppStorage(AppFont.preferenceKey) private var fontFamily = ""
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 22

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> MarkdownWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "markdown")
        let view = MarkdownWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view
        context.coordinator.loadPreview()
        return view
    }

    func updateNSView(_ view: MarkdownWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.update(text: text, fontFamily: fontFamily, dark: colorScheme == .dark)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MarkdownWebView, context: Context) -> CGSize? {
        let available = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 620
        guard available > 0 else { return .zero }
        var width = available
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !text.contains("\n"), text.count < 160,
           !["#", ">", "- ", "* ", "+ ", "`", "|"].contains(where: trimmed.hasPrefix),
           trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) == nil {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let plain = (try? AttributedString(markdown: text, options: options)).map { String($0.characters) } ?? text
            let font = (!fontFamily.isEmpty ? NSFont(name: fontFamily, size: 13.5) : nil) ?? .systemFont(ofSize: 13.5)
            let natural = (plain as NSString).size(withAttributes: [.font: font]).width
            width = min(available, ceil(natural * 1.03) + 8)
        }
        return CGSize(width: max(1, width), height: max(1, height))
    }

    static func dismantleNSView(_ view: MarkdownWebView, coordinator: Coordinator) {
        coordinator.stop()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "markdown")
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        weak var webView: MarkdownWebView?
        private var source: String?
        private var fontFamily = ""
        private var dark = false
        private var ready = false
        private var rendered: MarkdownRenderer.Result?
        private var renderTask: Task<Void, Never>?
        private var lastRenderStarted: UInt64 = 0

        private var previewURL: URL? {
            Bundle.main.resourceURL?.appendingPathComponent("MarkdownPreview.bundle/index.html")
        }

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func loadPreview() {
            guard let url = previewURL else { return }
            ready = false
            webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        func update(text: String, fontFamily: String, dark: Bool) {
            if self.fontFamily != fontFamily || self.dark != dark {
                self.fontFamily = fontFamily
                self.dark = dark
                updateAppearance()
            }
            guard source != text else { return }
            source = text
            scheduleRender()
        }

        private func scheduleRender() {
            guard renderTask == nil, source != nil else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = lastRenderStarted == 0 ? UInt64.max : now - lastRenderStarted
            let delay = elapsed >= 80_000_000 ? 0 : 80_000_000 - elapsed
            renderTask = Task { [weak self] in
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled, let self, let text = self.source else { return }
                self.lastRenderStarted = DispatchTime.now().uptimeNanoseconds
                let result = await Task.detached(priority: .userInitiated) { MarkdownRenderer.render(text) }.value
                guard !Task.isCancelled else { return }
                self.rendered = result
                self.showRendered()
                self.renderTask = nil
                if self.source != text { self.scheduleRender() }
            }
        }

        func stop() {
            renderTask?.cancel()
            renderTask = nil
            webView = nil
        }

        private func showRendered() {
            guard ready, let rendered, let webView else { return }
            webView.callAsyncJavaScript(
                "window.markdownPreview.render(data)",
                arguments: ["data": ["html": rendered.html, "containsMath": rendered.containsMath]],
                in: nil, in: .page
            ) { _ in }
        }

        private func updateAppearance() {
            guard ready, let webView else { return }
            webView.callAsyncJavaScript(
                "window.markdownPreview.setAppearance(theme, font)",
                arguments: ["theme": dark ? "dark" : "light", "font": fontFamily],
                in: nil, in: .page
            ) { _ in }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                updateAppearance()
                showRendered()
            case "size":
                guard let value = body["height"] as? NSNumber else { return }
                let next = CGFloat(truncating: value)
                guard next.isFinite, next > 0, abs(next - height.wrappedValue) >= 1 else { return }
                height.wrappedValue = next
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if url.isFileURL, url.standardizedFileURL.path == previewURL?.standardizedFileURL.path {
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .linkActivated, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loadPreview()
        }
    }
}

final class MarkdownWebView: WKWebView {
    private var dragScrollTimer: Timer?
    private var lastDragEvent: NSEvent?

    deinit { dragScrollTimer?.invalidate() }

    override func mouseDown(with event: NSEvent) {
        stopDragScrolling()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        lastDragEvent = event
        if autoscroll(with: event) {
            if dragScrollTimer == nil {
                let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
                    self?.continueDragScrolling()
                }
                RunLoop.main.add(timer, forMode: .common)
                dragScrollTimer = timer
            }
        } else {
            dragScrollTimer?.invalidate()
            dragScrollTimer = nil
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        stopDragScrolling()
        super.mouseUp(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopDragScrolling() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func continueDragScrolling() {
        guard let event = lastDragEvent, autoscroll(with: event) else {
            stopDragScrolling()
            return
        }
        super.mouseDragged(with: event)
    }

    private func stopDragScrolling() {
        dragScrollTimer?.invalidate()
        dragScrollTimer = nil
        lastDragEvent = nil
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), let outer = superview?.enclosingScrollView {
            outer.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
