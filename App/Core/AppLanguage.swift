import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    /// Native names stay recognizable even when the rest of the UI is using
    /// the other language.
    var nativeName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    var secondaryName: String {
        switch self {
        case .simplifiedChinese: return "Chinese (Simplified)"
        case .english: return "英语"
        }
    }

    static var systemDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }
}

@MainActor
final class AppLanguageSettings: ObservableObject {
    private static let languageKey = "openfly.app.language"
    private static let selectionCompletedKey = "openfly.app.language-selection-completed"

    @Published private(set) var language: AppLanguage
    @Published private(set) var selectionCompleted: Bool

    init(defaults: UserDefaults = .standard) {
        language = defaults.string(forKey: Self.languageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .systemDefault
        selectionCompleted = defaults.bool(forKey: Self.selectionCompletedKey)
        if ProcessInfo.processInfo.arguments.contains("--survey-ui-preview")
            || ProcessInfo.processInfo.arguments.contains("--map-ui-preview") {
            selectionCompleted = true
        }
    }

    func select(_ language: AppLanguage, completeOnboarding: Bool = true) {
        self.language = language
        if completeOnboarding { selectionCompleted = true }
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: Self.languageKey)
        if completeOnboarding { defaults.set(true, forKey: Self.selectionCompletedKey) }
    }
}

/// Localizes strings that are assembled before they reach SwiftUI. SwiftUI's
/// environment locale handles literal `Text` and `Button` labels, while status
/// messages and formatted mission statistics use this companion lookup.
enum AppLocalization {
    static var selectedLanguage: AppLanguage {
        UserDefaults.standard.string(forKey: "openfly.app.language")
            .flatMap(AppLanguage.init(rawValue:)) ?? .systemDefault
    }

    static func string(_ key: String) -> String {
        let language = selectedLanguage
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: selectedLanguage.locale, arguments: arguments)
    }

    /// Localizes status and diagnostic messages produced by providers before
    /// they reach SwiftUI. Exact catalog keys are preferred; a small set of
    /// formatted provider messages is handled explicitly so English logs and
    /// banners do not leak Chinese prefixes around dynamic DJI values.
    static func runtime(_ message: String) -> String {
        let exact = string(message)
        if exact != message { return exact }

        let formattedPrefixes: [(String, String)] = [
            ("产品已连接：", "产品已连接：%@"),
            ("MSDK 注册失败：", "MSDK 注册失败：%@"),
            ("DJI 账号登录失败：", "DJI 账号登录失败：%@")
        ]
        for (prefix, formatKey) in formattedPrefixes where message.hasPrefix(prefix) {
            return format(formatKey, String(message.dropFirst(prefix.count)))
        }
        return message
    }
}
