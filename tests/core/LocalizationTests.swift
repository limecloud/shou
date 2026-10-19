import Foundation
import ShouCore

func desktopLanguageDefaultsAndSavedChoice() throws {
    try expect(AppLanguage(savedValue: nil) == .simplifiedChinese)
    try expect(AppLanguage(savedValue: "unsupported") == .simplifiedChinese)
    try expect(AppLanguage(savedValue: "en") == .english)
    try expect(AppLanguage(savedValue: "zh-CN") == .simplifiedChinese)
}

func localizedResourcesSwitchWithoutProcessRestart() throws {
    // Exercise Bundle lookup against SwiftPM's generated localization names,
    // including switching back after an English lookup in the same process.
    for language in [AppLanguage.simplifiedChinese, .english, .simplifiedChinese] {
        let chinese=language == .simplifiedChinese
        try expect(L10n.string("Cleanup", locale: language.rawValue) == (chinese ? "清理" : "Cleanup"))
        try expect(L10n.string("Language", locale: language.rawValue) == (chinese ? "语言" : "Language"))
        try expect(L10n.string("Name", locale: language.rawValue) == (chinese ? "名称" : "Name"))
        try expect(L10n.string("Incomplete scan", locale: language.rawValue) == (chinese ? "扫描未完成" : "Incomplete scan"))
        try expect(L10n.string("untranslated-personal-rule", locale: language.rawValue) == "untranslated-personal-rule")
    }
}
