import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-CN"
    case english = "en"

    public init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .simplifiedChinese
    }

    public var title: String { self == .simplifiedChinese ? "简体中文" : "English" }
    public var locale: Locale { Locale(identifier: rawValue) }
}

public enum L10n {
    public static func string(_ key: String, locale: String) -> String {
        let language=locale == "zh-CN" ? "zh-Hans" : "en"
        // SwiftPM supplies .strings generated from the source String Catalog.
        let resources=CoreResources.bundle
        // SwiftPM lowercases localization directory names. Resolve the actual
        // resource tag instead of relying on case-insensitive Bundle lookup.
        guard let tag=resources.localizations.first(where: { $0.caseInsensitiveCompare(language) == .orderedSame }),
              let path=resources.path(forResource: tag, ofType: "lproj"),
              let localized=Bundle(path: path) else { return key }
        return localized.localizedString(forKey: key, value: key, table: nil)
    }
}
