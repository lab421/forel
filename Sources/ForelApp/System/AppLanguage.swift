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

import AppKit
import Foundation

/// Forel's own language, independent of the Mac's.
///
/// It is the per-app `AppleLanguages` preference, the one System Settings >
/// General > Language & Region > Applications writes, so both places always
/// agree. macOS reads it at launch: a change applies after a relaunch.
enum AppLanguage {
    private static let key = "AppleLanguages"

    /// The languages Forel ships, from its own `.lproj` folders.
    static var available: [String] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted { nativeName($0).localizedStandardCompare(nativeName($1)) == .orderedAscending }
    }

    /// The language chosen for Forel only, or `nil` to follow the Mac.
    static var choice: String? {
        get {
            guard let bundleID = Bundle.main.bundleIdentifier,
                  let preferred = UserDefaults.standard.persistentDomain(forName: bundleID)?[key] as? [String],
                  !preferred.isEmpty else { return nil }
            return Bundle.preferredLocalizations(from: available, forPreferences: preferred).first
        }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// The language Forel is showing right now.
    static var current: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// The language Forel will show after its next launch.
    static var next: String {
        let preferences = UserDefaults.standard.stringArray(forKey: key) ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: available, forPreferences: preferences).first ?? current
    }

    /// A language's name in that language ("Français", "Deutsch"), as
    /// language menus show them.
    static func nativeName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code
    }

    /// A language's name in the language Forel is showing ("allemand").
    static func displayName(_ code: String) -> String {
        Locale(identifier: current).localizedString(forLanguageCode: code) ?? nativeName(code)
    }

    /// Quits, then opens Forel again once this process has exited, so two
    /// instances never watch the same folders at once.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$2""#,
            "forel-relaunch", "\(ProcessInfo.processInfo.processIdentifier)", Bundle.main.bundleURL.path,
        ]
        do {
            try process.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}
