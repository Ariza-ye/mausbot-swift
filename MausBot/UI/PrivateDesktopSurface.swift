import AppKit
import SwiftUI

struct PrivateDesktopSurface: NSViewRepresentable {
    @ObservedObject var desktop: PrivateDesktop

    func makeNSView(context: Context) -> DesktopView {
        let view = DesktopView()
        view.desktop = desktop
        return view
    }

    func updateNSView(_ view: DesktopView, context: Context) {
        view.image = desktop.image
        view.needsDisplay = true
    }
}

final class DesktopView: NSView {
    weak var desktop: PrivateDesktop?
    var image: NSImage?
    private var buttons: UInt8 = 0
    private var modifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private var imageRect: NSRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func pointer(_ event: NSEvent) {
        guard let size = image?.size, imageRect.width > 0, imageRect.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let x = Int((p.x - imageRect.minX) * size.width / imageRect.width)
        let y = Int((p.y - imageRect.minY) * size.height / imageRect.height)
        desktop?.pointer(x: x, y: y, buttons: buttons)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; pointer(event) }
    override func mouseUp(with event: NSEvent) { buttons &= ~1; pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); buttons |= 4; pointer(event) }
    override func rightMouseUp(with event: NSEvent) { buttons &= ~4; pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDown(with event: NSEvent) { buttons |= 2; pointer(event) }
    override func otherMouseUp(with event: NSEvent) { buttons &= ~2; pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }
    override func scrollWheel(with event: NSEvent) {
        let flag: UInt8 = event.scrollingDeltaY > 0 ? 8 : 16
        guard event.scrollingDeltaY != 0 else { return }
        buttons |= flag; pointer(event); buttons &= ~flag; pointer(event)
    }

    private func keyValue(_ event: NSEvent) -> UInt32? {
        switch event.keyCode {
        case 36: return 0xff0d
        case 48: return 0xff09
        case 51: return 0xff08
        case 53: return 0xff1b
        case 117: return 0xffff
        case 123: return 0xff51
        case 124: return 0xff53
        case 125: return 0xff54
        case 126: return 0xff52
        case 115: return 0xff50
        case 119: return 0xff57
        case 116: return 0xff55
        case 121: return 0xff56
        default:
            guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
            let value = scalar.value
            guard value >= 32 && !(0xf700...0xf8ff).contains(value) else { return nil }
            return value <= 255 ? value : 0x01000000 | value
        }
    }
    override func keyDown(with event: NSEvent) { if let key = keyValue(event) { desktop?.key(key, down: true) } }
    override func keyUp(with event: NSEvent) { if let key = keyValue(event) { desktop?.key(key, down: false) } }
    override func flagsChanged(with event: NSEvent) {
        let flags: [(NSEvent.ModifierFlags, UInt32)] = [(.shift, 0xffe1), (.control, 0xffe3), (.option, 0xffe9), (.command, 0xffeb)]
        for (flag, key) in flags where modifiers.contains(flag) != event.modifierFlags.contains(flag) {
            desktop?.key(key, down: event.modifierFlags.contains(flag))
        }
        modifiers = event.modifierFlags
    }
    override func resignFirstResponder() -> Bool {
        for (flag, key): (NSEvent.ModifierFlags, UInt32) in [(.shift, 0xffe1), (.control, 0xffe3), (.option, 0xffe9), (.command, 0xffeb)] where modifiers.contains(flag) {
            desktop?.key(key, down: false)
        }
        modifiers = []
        return super.resignFirstResponder()
    }
}
