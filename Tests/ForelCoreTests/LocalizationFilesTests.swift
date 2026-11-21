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
import Testing
@testable import ForelCore

/// Keeps `Localization/<language>.lproj/Localizable.strings` in step with the
/// `L10n.string("…")` and `L10n.plural("…")` keys the code uses.
struct LocalizationFilesTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let localization = repoRoot.appendingPathComponent("Localization")

    private static var languages: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: localization.path)) ?? []
        return names.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }.sorted()
    }

    private static func table(_ language: String) -> [String: String]? {
        let url = localization.appendingPathComponent("\(language).lproj/Localizable.strings")
        return NSDictionary(contentsOf: url) as? [String: String]
    }

    private static func swiftSources(in folder: String) -> [(path: String, text: String)] {
        let root = repoRoot.appendingPathComponent(folder)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (url.path.replacingOccurrences(of: repoRoot.path + "/", with: ""), $0) }
        }
    }

    /// Every key the code reads, with "_one" and "_other" for plurals.
    private static let usedKeys: Set<String> = {
        let pattern = try! NSRegularExpression(pattern: #"L10n\.(string|plural)\(\s*"([A-Za-z0-9_]+)""#)
        var keys = Set<String>()
        for source in swiftSources(in: "Sources") {
            let text = source.text as NSString
            for match in pattern.matches(in: source.text, range: NSRange(location: 0, length: text.length)) {
                let key = text.substring(with: match.range(at: 2))
                if text.substring(with: match.range(at: 1)) == "plural" {
                    keys.insert("\(key)_one")
                    keys.insert("\(key)_other")
                } else {
                    keys.insert(key)
                }
            }
        }
        return keys
    }()

    private static func placeholders(_ value: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(\d+\$)?(@|ll?[a-zA-Z]|[a-zA-Z])"#)
        return pattern.matches(in: value, range: NSRange(value.startIndex..., in: value))
            .map { (value as NSString).substring(with: $0.range) }
    }

    @Test func everyLanguageFileReads() throws {
        #expect(Self.languages.contains("en"))
        for language in Self.languages {
            #expect(Self.table(language) != nil, "\(language).lproj/Localizable.strings has a syntax error")
            // A key written twice silently keeps only its last value.
            let text = try String(contentsOf: Self.localization.appendingPathComponent("\(language).lproj/Localizable.strings"), encoding: .utf8)
            let keys = text.split(separator: "\n").compactMap { line -> Substring? in
                guard line.hasPrefix("\""), let end = line.dropFirst().firstIndex(of: "\"") else { return nil }
                return line[line.index(after: line.startIndex)..<end]
            }
            let duplicates = Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            #expect(duplicates.isEmpty, "Written twice in \(language): \(duplicates.joined(separator: ", "))")
        }
    }

    @Test func everyKeyTheCodeUsesHasEnglishText() {
        let english = Self.table("en") ?? [:]
        let missing = Self.usedKeys.subtracting(english.keys).sorted()
        #expect(missing.isEmpty, "Missing from en.lproj/Localizable.strings: \(missing.joined(separator: ", "))")
    }

    @Test func englishHasNoUnusedKeys() {
        let english = Self.table("en") ?? [:]
        let unused = Set(english.keys).subtracting(Self.usedKeys).sorted()
        #expect(unused.isEmpty, "Not used by the code anymore: \(unused.joined(separator: ", "))")
    }

    @Test func everyLanguageTranslatesExactlyTheEnglishKeys() {
        let english = Set((Self.table("en") ?? [:]).keys)
        for language in Self.languages where language != "en" {
            let keys = Set((Self.table(language) ?? [:]).keys)
            let missing = english.subtracting(keys).sorted()
            let extra = keys.subtracting(english).sorted()
            #expect(missing.isEmpty, "Not translated in \(language): \(missing.joined(separator: ", "))")
            #expect(extra.isEmpty, "Not in English, so unused, in \(language): \(extra.joined(separator: ", "))")
        }
    }

    /// Values only use %@ (or %1$@, %2$@…), and each translation keeps
    /// English's placeholders, so no value reads a missing argument. A
    /// singular form may leave the number out ("Premier élément vérifié").
    @Test func translationsKeepTheirPlaceholders() {
        let english = Self.table("en") ?? [:]
        for language in Self.languages {
            for (key, value) in Self.table(language) ?? [:] {
                let found = Self.placeholders(value)
                #expect(found.allSatisfy { $0.hasSuffix("@") }, "\(language) \(key) uses \(found); values only use %@")
                if language != "en", let source = english[key] {
                    let expected = Self.placeholders(source).count
                    let allowed = key.hasSuffix("_one") ? (expected - 1)...expected : expected...expected
                    #expect(allowed.contains(found.count), "\(language) \(key) has \(found.count) placeholders, English has \(expected)")
                }
            }
        }
    }

    /// SwiftUI shows a literal like Text("Settings") as is, so text the user
    /// reads must go through L10n.string. Literals without letters ("\(count)")
    /// and Text(verbatim:) are fine.
    @Test func appTextIsNotHardCoded() {
        let call = try! NSRegularExpression(pattern: #"\b(Text|Button|Toggle|Label|Picker|Section|TextField|SecureField|Menu|LabeledContent)\(\s*"((?:[^"\\]|\\.)*)"|\.(help|alert|navigationTitle|accessibilityLabel|accessibilityHint|confirmationDialog|setAccessibilityLabel)\(\s*"((?:[^"\\]|\\.)*)""#)
        let interpolation = try! NSRegularExpression(pattern: #"\\\([^)]*\)"#)
        var hardCoded: [String] = []
        for source in Self.swiftSources(in: "Sources/ForelApp") {
            let text = source.text as NSString
            for match in call.matches(in: source.text, range: NSRange(location: 0, length: text.length)) {
                let range = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 4)
                let literal = text.substring(with: range)
                let withoutInterpolations = interpolation.stringByReplacingMatches(
                    in: literal, range: NSRange(location: 0, length: (literal as NSString).length), withTemplate: ""
                )
                if withoutInterpolations.contains(where: \.isLetter) {
                    hardCoded.append("\(source.path): \(text.substring(with: match.range))")
                }
            }
        }
        #expect(hardCoded.isEmpty, "Use L10n.string for: \(hardCoded.joined(separator: "; "))")
    }

    @Test func pluralsPickTheFormForTheLanguage() {
        #expect(L10n.usesOneForm(1, language: "en"))
        #expect(!L10n.usesOneForm(0, language: "en"))
        #expect(!L10n.usesOneForm(2, language: "de"))
        #expect(L10n.usesOneForm(0, language: "fr"))
        #expect(L10n.usesOneForm(1, language: "fr-CA"))
        #expect(!L10n.usesOneForm(2, language: "fr"))
        #expect(L10n.plural("rule_list_rules_selected", 1) == "1 rule selected")
        #expect(L10n.plural("rule_list_rules_selected", 3) == "3 rules selected")
    }
}
