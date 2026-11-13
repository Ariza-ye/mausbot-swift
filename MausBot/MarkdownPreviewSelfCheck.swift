import AppKit
import SwiftUI
import WebKit

@MainActor
enum MarkdownPreviewSelfCheck {
    private final class Sample: ObservableObject {
        @Published var text: String
        @Published var dark = false
        init(_ text: String) { self.text = text }
    }

    private struct SampleView: View {
        @ObservedObject var sample: Sample
        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading) {
                    MarkdownText(text: sample.text)
                }
                .padding(16)
            }
            .background(sample.dark ? Color.black : Color.white)
            .preferredColorScheme(sample.dark ? .dark : .light)
        }
    }

    private struct ManyMessagesView: View {
        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<100, id: \.self) { index in
                        MarkdownText(text: "第\(index)条回复\n\n这是用于检查长对话的内容。")
                    }
                }
                .padding(16)
            }
        }
    }

    private final class ScrollSpy: NSScrollView {
        var received: NSEvent?
        override func scrollWheel(with event: NSEvent) { received = event }
    }

    static func run() async -> Int32 {
        _ = NSApplication.shared
        let source = """
        # 标题文字

        第一段文字和 **重点**，还有 [链接](https://example.com)。

        第二段内容。

        - 外层
          - 内层

        | 名称 | 结果 |
        | --- | --- |
        | 检查 | 通过 |

        ```swift
        let message = "hello"
        ```

        公式 $x_{i+1} = a*b$，价格 $5 和 $10。

        $$
        y = x_1 + a*b
        $$

        ```mermaid
        graph LR
          A[开始] --> B[完成]
        ```

        收尾文字
        """
        let sample = Sample(source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SampleView(sample: sample))
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        window.makeKey()
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 640)
        host.layoutSubtreeIfNeeded()
        host.display()

        func findWebView(_ view: NSView) -> WKWebView? {
            if let web = view as? MarkdownWebView { return web }
            return view.subviews.lazy.compactMap(findWebView).first
        }
        guard let webView = findWebView(host) else {
            print("FAIL markdown preview did not create a web view")
            return 1
        }

        func waitFor(_ expression: String) async -> Bool {
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if (try? await webView.evaluateJavaScript(expression)) as? Bool == true { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print("\(passed ? "ok  " : "FAIL") \(name)")
            if !passed { failures += 1 }
        }

        let basic = await waitFor("Boolean(document.querySelector('#content h1') && document.querySelector('#content table'))")
        check("web preview renders markdown and tables", basic)
        let enhanced = await waitFor("Boolean(document.querySelector('.hljs-keyword') && document.querySelector('.katex-display') && document.querySelectorAll('.skip-math-dollar').length === 2 && document.querySelector('pre.diagram svg')?.textContent.includes('开始') && document.querySelector('pre.diagram svg')?.textContent.includes('完成'))")
        check("code highlighting, math and mermaid render offline", enhanced)
        if !enhanced {
            let details = try? await webView.evaluateJavaScript("({url: location.href, ready: typeof window.markdownPreview, purify: typeof DOMPurify, highlight: typeof hljs, katex: typeof katex, mermaid: typeof mermaid, content: document.getElementById('content')?.innerHTML})")
            print("preview diagnostics: \(String(describing: details))")
        }
        check("preview height follows rendered content", webView.frame.height > 100 && webView.enclosingScrollView != nil)
        if webView.frame.height <= 100 {
            let size = try? await webView.evaluateJavaScript("({body: document.body.scrollHeight, content: document.getElementById('content').getBoundingClientRect().height, viewport: window.innerHeight})")
            print("preview size: frame=\(webView.frame), container=\(String(describing: webView.enclosingScrollView)), DOM=\(String(describing: size))")
        }
        let scrollSpy = ScrollSpy(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let wheelTarget = MarkdownWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 400), configuration: WKWebViewConfiguration())
        scrollSpy.documentView = document
        document.addSubview(wheelTarget)
        if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)) {
            wheelTarget.scrollWheel(with: wheel)
            check("vertical wheel events reach the transcript scroll view", scrollSpy.received === wheel)
        } else {
            check("vertical wheel events reach the transcript scroll view", false)
        }
        let coordinates = try? await webView.evaluateJavaScript("""
            (() => {
              const title = document.querySelector('#content h1').getBoundingClientRect();
              const paragraph = document.querySelectorAll('#content p')[1].getBoundingClientRect();
              return { x1: title.left + 2, y1: title.top + title.height / 2, x2: paragraph.left + 65, y2: paragraph.top + paragraph.height / 2 };
            })()
            """) as? [String: NSNumber]
        if let coordinates {
            func windowPoint(_ x: String, _ y: String) -> NSPoint {
                let vertical = CGFloat(truncating: coordinates[y]!)
                return webView.convert(NSPoint(x: CGFloat(truncating: coordinates[x]!), y: webView.isFlipped ? vertical : webView.bounds.height - vertical), to: nil)
            }
            let start = windowPoint("x1", "y1")
            let end = windowPoint("x2", "y2")
            var eventNumber = 0
            func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                eventNumber += 1
                return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 1)!
            }
            window.makeFirstResponder(webView)
            window.sendEvent(mouse(.leftMouseDown, start))
            try? await Task.sleep(nanoseconds: 100_000_000)
            window.sendEvent(mouse(.leftMouseDragged, end))
            try? await Task.sleep(nanoseconds: 100_000_000)
            window.sendEvent(mouse(.leftMouseUp, end))
            try? await Task.sleep(nanoseconds: 400_000_000)
            let dragged = try? await webView.evaluateJavaScript("window.getSelection().toString()") as? String
            let dragPassed = dragged?.contains("第一段文字") == true && dragged?.contains("第二段") == true
            check("mouse drag selects across markdown blocks", dragPassed)
            if !dragPassed { print("drag diagnostics: start=\(start) end=\(end) flipped=\(webView.isFlipped) hit=\(String(describing: host.hitTest(start))) selection=\(String(describing: dragged))") }
            sample.text = source + "\n\n" + (1...50).map { "第\($0)段：需要向下滚动才能看到的内容。" }.joined(separator: "\n\n")
            let longReply = await waitFor("window.innerHeight > 1200")
            if longReply, let outer = webView.enclosingScrollView {
                _ = try? await webView.evaluateJavaScript("window.testEvents=[]; ['mousedown','mousemove','mouseup'].forEach(t=>document.addEventListener(t, e=>window.testEvents.push([e.type,e.clientX,e.clientY])))")
                let original = outer.contentView.bounds.origin.y
                let outside = NSPoint(x: start.x, y: -40)
                window.sendEvent(mouse(.leftMouseDown, start))
                try? await Task.sleep(nanoseconds: 100_000_000)
                window.sendEvent(mouse(.leftMouseDragged, outside))
                let afterFirstDrag = outer.contentView.bounds.origin.y
                try? await Task.sleep(nanoseconds: 100_000_000)
                let firstSelectionLength = (try? await webView.evaluateJavaScript("window.getSelection().toString().length")) as? Int ?? 0
                try? await Task.sleep(nanoseconds: 500_000_000)
                let afterHolding = outer.contentView.bounds.origin.y
                let heldSelectionLength = (try? await webView.evaluateJavaScript("window.getSelection().toString().length")) as? Int ?? 0
                for _ in 0..<8 {
                    window.sendEvent(mouse(.leftMouseDragged, outside))
                    try? await Task.sleep(nanoseconds: 70_000_000)
                }
                window.sendEvent(mouse(.leftMouseUp, outside))
                let final = outer.contentView.bounds.origin.y
                check("dragging a long reply scrolls the transcript", final > original)
                check("holding the pointer outside keeps scrolling", afterHolding > afterFirstDrag)
                check("holding the pointer extends the selection", heldSelectionLength > firstSelectionLength)
                let extendedSelection = try? await webView.evaluateJavaScript("window.getSelection().toString()") as? String
                check("selection extends while the transcript scrolls", extendedSelection?.contains("第5段") == true)
                if extendedSelection?.contains("第5段") != true {
                    let tail = extendedSelection.map { String($0.suffix(160)) } ?? ""
                    let events = try? await webView.evaluateJavaScript("window.testEvents")
                    print("selection diagnostics: length=\(extendedSelection?.count ?? -1), tail=\(tail), events=\(String(describing: events)), scroll=\(final)")
                }
                if final <= original { print("scroll diagnostics: before=\(original), after=\(final), visible=\(outer.contentView.bounds), frame=\(webView.frame)") }
            } else {
                check("dragging a long reply scrolls the transcript", false)
                check("holding the pointer outside keeps scrolling", false)
                check("holding the pointer extends the selection", false)
                check("selection extends while the transcript scrolls", false)
            }
        } else {
            check("mouse drag selects across markdown blocks", false)
            check("dragging a long reply scrolls the transcript", false)
            check("holding the pointer outside keeps scrolling", false)
            check("holding the pointer extends the selection", false)
            check("selection extends while the transcript scrolls", false)
        }
        window.setContentSize(NSSize(width: 260, height: 640))
        host.frame.size.width = 260
        host.layoutSubtreeIfNeeded()
        let resized = await waitFor("window.innerWidth < 260 && Math.abs(window.innerHeight - Math.ceil(document.getElementById('content').getBoundingClientRect().height)) <= 2")
        check("preview resizes and wraps in narrow windows", resized)
        sample.dark = true
        let themed = await waitFor("document.documentElement.dataset.theme === 'dark' && Boolean(document.querySelector('pre.diagram svg'))")
        check("preview follows the application theme", themed)

        let selected = try? await webView.evaluateJavaScript("""
            (() => {
              const start = document.querySelector('#content h1').firstChild;
              const end = [...document.querySelectorAll('#content p')].find(p => p.textContent.includes('收尾文字')).firstChild;
              const range = document.createRange();
              range.setStart(start, 0); range.setEnd(end, end.length);
              const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
              return selection.toString();
            })()
            """) as? String
        check("selection spans headings and paragraphs", selected?.contains("第一段文字") == true && selected?.contains("收尾文字") == true)
        check("selection does not include diagram styling", selected?.contains("#maus-diagram-") == false)
        sample.text += "，继续更新"
        let updated = await waitFor("document.querySelector('#content')?.textContent.includes('继续更新') === true")
        let selectionAfterUpdate = try? await webView.evaluateJavaScript("window.getSelection().toString()") as? String
        check("streaming preserves the selected text", updated && selectionAfterUpdate == selected)

        var sawStreamingText = false
        for index in 0..<10 {
            sample.text = source + "\n\n流式内容 \(index)"
            try? await Task.sleep(nanoseconds: 50_000_000)
            if index < 9, (try? await webView.evaluateJavaScript("document.querySelector('#content')?.textContent.includes('流式内容')")) as? Bool == true {
                sawStreamingText = true
            }
        }
        let latestStream = await waitFor("document.querySelector('#content')?.textContent.includes('流式内容 9') === true")
        check("continuous streaming shows intermediate and final updates", sawStreamingText && latestStream)

        let unsafe = "<p onclick=\"window.bad=1\">safe</p><script>window.bad=1</script><img src=\"file:///etc/passwd\" onerror=\"window.bad=1\"><a href=\"javascript:alert(1)\">bad</a>"
        await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript("window.markdownPreview.render({html, containsMath: false})", arguments: ["html": unsafe], in: nil, in: .page) { _ in
                continuation.resume()
            }
        }
        let safe = (try? await webView.evaluateJavaScript("window.bad === undefined && !document.querySelector('#content script, #content [onclick], #content [onerror], #content img[src^=\"file:\"], #content a[href^=\"javascript:\"]')")) as? Bool == true
        check("untrusted HTML and local file URLs are removed", safe)

        let listWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 480, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        let listHost = NSHostingView(rootView: ManyMessagesView())
        listWindow.contentView = listHost
        listWindow.orderFrontRegardless()
        listHost.frame = NSRect(x: 0, y: 0, width: 480, height: 640)
        listHost.layoutSubtreeIfNeeded()
        listHost.display()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        listHost.layoutSubtreeIfNeeded()
        func allWebViews(_ view: NSView) -> [MarkdownWebView] {
            if let preview = view as? MarkdownWebView { return [preview] }
            return view.subviews.flatMap(allWebViews)
        }
        let visiblePreviews = allWebViews(listHost)
        check("long conversations create previews lazily", !visiblePreviews.isEmpty && visiblePreviews.count < 100)
        listWindow.orderOut(nil)
        print(failures == 0 ? "PASS" : "FAIL \(failures) checks")
        return failures == 0 ? 0 : 1
    }
}
