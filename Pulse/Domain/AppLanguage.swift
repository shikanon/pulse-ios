import Foundation

enum PulseAppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let storageKey = "pulse.app-language"

    // Keep the existing English experience on upgrade; people can switch to
    // Simplified Chinese at any time from Settings.
    static let defaultLanguage: PulseAppLanguage = .english

    static var selected: PulseAppLanguage {
        guard let stored = UserDefaults.standard.string(forKey: storageKey),
              let language = PulseAppLanguage(rawValue: stored)
        else { return defaultLanguage }
        return language
    }

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    func localizedString(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return Bundle.main.localizedString(forKey: key, value: key, table: nil) }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
