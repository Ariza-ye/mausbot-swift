import AppKit
import SwiftUI

enum AppFont {
    static let preferenceKey = "fontFamily"

    static var availableFamilies: [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func font(family: String, size: CGFloat, weight: Font.Weight, design: Font.Design) -> Font {
        guard !family.isEmpty, design != .monospaced,
              let font = NSFont(name: family, size: size) else {
            return .system(size: size, weight: weight, design: design)
        }
        return Font.custom(font.fontName, fixedSize: size).weight(weight)
    }
}

private struct AppFontModifier: ViewModifier {
    @AppStorage(AppFont.preferenceKey) private var family = ""
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(AppFont.font(family: family, size: size, weight: weight, design: design))
    }
}

extension View {
    func appFont(size: CGFloat = NSFont.systemFontSize, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(AppFontModifier(size: size, weight: weight, design: design))
    }
}
