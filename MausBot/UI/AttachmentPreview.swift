import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum AttachmentImageActions {
    static func copy(_ attachment: Attachment, store: AppStore, pasteboard: NSPasteboard = .general) async throws {
        let data = try await store.imageData(path: attachment.path)
        guard let image = NSImage(data: data) else {
            throw APIError(status: 0, message: localized("无法识别图片格式"), body: nil)
        }
        let item = NSPasteboardItem()
        if let type = contentType(for: data) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw APIError(status: 0, message: localized("无法复制图片"), body: nil)
        }
    }

    static func save(_ attachment: Attachment, store: AppStore) async throws {
        let window = NSApp.keyWindow
        let data = try await store.imageData(path: attachment.path)
        let panel = NSSavePanel()
        let type = contentType(for: data) ?? UTType(mimeType: attachment.mime) ?? .image
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = attachment.name ?? URL(string: attachment.path)?.lastPathComponent ?? localized("图片")
        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    private static func contentType(for data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) else { return nil }
        return UTType(identifier as String)
    }
}

struct AttachmentImageButtons: View {
    let attachment: Attachment
    var onError: (String) -> Void
    @EnvironmentObject private var store: AppStore
    @State private var working = false

    var body: some View {
        Group {
            Button {
                perform { try await AttachmentImageActions.copy(attachment, store: store) }
            } label: {
                Label("复制图片", systemImage: "doc.on.doc")
            }
            Button {
                perform { try await AttachmentImageActions.save(attachment, store: store) }
            } label: {
                Label("图片另存为…", systemImage: "square.and.arrow.down")
            }
        }
        .disabled(working)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try await action()
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

@MainActor
final class AttachmentPreviewWindow: NSObject, NSWindowDelegate {
    private static var openWindows: [String: AttachmentPreviewWindow] = [:]
    private let key: String
    private let window: NSWindow

    @discardableResult
    static func open(attachment: Attachment, store: AppStore) -> NSWindow {
        let key = "\(store.computer?.id ?? ""):\(attachment.path)"
        if let existing = openWindows[key] {
            existing.window.makeKeyAndOrderFront(nil)
            return existing.window
        }
        let controller = AttachmentPreviewWindow(key: key, attachment: attachment, store: store)
        openWindows[key] = controller
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        return controller.window
    }

    private init(key: String, attachment: Attachment, store: AppStore) {
        self.key = key
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        self.window = window
        super.init()
        window.title = attachment.name ?? localized("图片")
        window.contentMinSize = NSSize(width: 460, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView:
            AttachmentPreview(attachment: attachment, close: { [weak window] in
                window?.performClose(nil)
            })
            .environmentObject(store)
            .environment(\.locale, AppLanguage.current.locale))
    }

    func windowWillClose(_ notification: Notification) {
        Self.openWindows.removeValue(forKey: key)
    }
}

struct AttachmentPreview: View {
    let attachment: Attachment
    let close: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(attachment.name ?? localized("图片"))
                    .appFont(size: 13, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                AttachmentImageButtons(attachment: attachment) { error = $0 }
                Button("关闭", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            RemoteImage(path: attachment.path, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        }
        .frame(minWidth: 460, minHeight: 320)
        .alert("图片操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}
