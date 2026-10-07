import Foundation
import Observation
import Synchronization

/// Stored identifiers are independent of translated labels and survive upgrades.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L10n.string("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        let match = Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferredLanguages).first
        return match == "zh-Hans" ? .simplifiedChinese : .english
    }
    var locale: Locale { Locale(identifier: resolved().rawValue) }
}

/// Observation updates every view that resolves app text, without recreating the
/// player, sheets, text-field state, or visualization when the language changes.
/// The same strings are also safe to resolve inside background provider actors.
final class LocalizationState: Observable, Sendable {
    private let registrar = ObservationRegistrar()
    private let storedLanguage: Mutex<AppLanguage>

    init(_ language: AppLanguage) { storedLanguage = Mutex(language) }
    var language: AppLanguage {
        get {
            registrar.access(self, keyPath: \.language)
            return storedLanguage.withLock { $0 }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.language) {
                storedLanguage.withLock { $0 = newValue }
            }
        }
    }
}

enum L10n {
    static let preferenceKey = "app-language"
    private static let state = LocalizationState(preference(in: defaults))
    private static var defaults: UserDefaults { ProcessInfo.processInfo.environment["ALPACA_PREFERENCES_DOMAIN"]
        .flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
    private static let english = localizedBundle("en")
    private static let chinese = localizedBundle("zh-Hans")

    static var language: AppLanguage { state.language }
    static func setLanguage(_ language: AppLanguage) { state.language = language }
    static func preference(in defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
    static func string(_ value: String.LocalizationValue, language: AppLanguage? = nil) -> String {
        let resolved = (language ?? state.language).resolved()
        return String(localized: value, bundle: resolved == .simplifiedChinese ? chinese : english,
                      locale: resolved.locale)
    }
    private static func localizedBundle(_ language: String) -> Bundle {
        guard let url = Bundle.module.url(forResource: language, withExtension: "lproj"),
              let bundle = Bundle(url: url) else {
            preconditionFailure("Missing bundled localization: \(language)")
        }
        return bundle
    }
}
