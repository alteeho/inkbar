import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case russian
    case english

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.hasPrefix("ru") {
                return Locale(identifier: "ru")
            }
            return Locale(identifier: "en")
        case .russian:
            return Locale(identifier: "ru")
        case .english:
            return Locale(identifier: "en")
        }
    }
}

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    private static let key = "inkbar.language"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.key)
        }
    }

    var locale: Locale { language.locale }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let value = AppLanguage(rawValue: raw)
        {
            language = value
        } else {
            language = .system
        }
    }

    func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: localizationBundle, value: key, comment: "")
    }

    func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: args)
    }

    private var localizationBundle: Bundle {
        let code = locale.identifier.lowercased().hasPrefix("ru") ? "ru" : "en"
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }
        return .main
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buildVersion: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
