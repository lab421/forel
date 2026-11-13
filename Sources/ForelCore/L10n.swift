// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import os

/// Forel's translated text, looked up by key in
/// `Localization/<language>.lproj/Localizable.strings`.
///
///     L10n.string("settings_language")                  // "Langue"
///     L10n.string("rule_list_to", destination)          // "%@" in the value
///     L10n.plural("rule_list_rules_selected", count)    // "_one" / "_other" keys
///
/// Values only use `%@` (`%1$@`, `%2$@` when a translation reorders them);
/// integers are passed formatted for the current locale ("5 000"). A key
/// missing from the language shown falls back to English.
///
/// The app's bundle holds the `.lproj` folders, copied there by `build.sh`.
/// A debug build without them, such as `swift test`, reads English straight
/// from `Localization/en.lproj` in the source tree.
public enum L10n {
    public static func string(_ key: String, _ args: CVarArg...) -> String {
        format(value(for: key), args)
    }

    /// Reads `key_one` or `key_other` depending on `count`, which becomes the
    /// first `%@`; `args` follow it.
    public static func plural(_ key: String, _ count: Int, _ args: CVarArg...) -> String {
        let category = usesOneForm(count, language: language) ? "one" : "other"
        return format(value(for: "\(key)_\(category)"), [count] + args)
    }

    /// Whether `count` takes the singular ("_one") form in `language`. French
    /// treats 0 as singular ("0 fichier"); English, Spanish, and German only 1.
    /// A language with more plural forms needs its rule here.
    static func usesOneForm(_ count: Int, language: String) -> Bool {
        switch language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? language {
        case "fr", "pt":
            return count == 0 || count == 1
        default:
            return count == 1
        }
    }

    private static let missing = "\u{0}missing"
    private static let englishCache = OSAllocatedUnfairLock<(path: String, table: [String: String])?>(initialState: nil)

    private static var language: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    private static func value(for key: String) -> String {
        let found = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
        if found != missing { return found }
        return english[key] ?? key
    }

    private static var englishPath: String? {
        if let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") {
            return path
        }
        #if DEBUG
        let sourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Localization/en.lproj/Localizable.strings").path
        if FileManager.default.fileExists(atPath: sourceTree) { return sourceTree }
        #endif
        return nil
    }

    private static var english: [String: String] {
        guard let path = englishPath else { return [:] }
        return englishCache.withLock { cache in
            if let cache, cache.path == path { return cache.table }
            let table = NSDictionary(contentsOfFile: path) as? [String: String] ?? [:]
            cache = (path, table)
            return table
        }
    }

    private static func format(_ value: String, _ args: [CVarArg]) -> String {
        guard !args.isEmpty else { return value }
        let arguments: [CVarArg] = args.map { argument in
            switch argument {
            case let number as Int: return number.formatted()
            case let number as Int64: return number.formatted()
            case let number as Int32: return number.formatted()
            case let number as UInt: return number.formatted()
            default: return argument
            }
        }
        return String(format: value, locale: .current, arguments: arguments)
    }
}
