import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    static let preferenceKey = "appLanguage"
    var id: String { rawValue }
    var label: String { self == .chinese ? "简体中文" : "English" }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .chinese
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

func localized(_ key: String, _ arguments: CVarArg...) -> String {
    let language = AppLanguage.current
    guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
          let bundle = Bundle(path: path) else { return key }
    let format = bundle.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? format : String(format: format, locale: language.locale, arguments: arguments)
}
