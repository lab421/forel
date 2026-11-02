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

/// Bundled brand assets: the full-colour Forel leaf app icon and the white
/// glyph used in the menu bar (`Resources/AppIcon.png`, `Resources/TrayIcon.png`
@MainActor
enum AppIcons {
    static let appIcon: NSImage? = loadImage("AppIcon")
    /// White-on-transparent leaf glyph, sized down for the menu bar.
    static let trayGlyph: NSImage? = loadImage("TrayIcon")

    private static func loadImage(_ name: String) -> NSImage? {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: name, withExtension: "png"),
            Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources"),
            Bundle.main.resourceURL?.appendingPathComponent("Forel_ForelApp.bundle/Resources/\(name).png"),
            Bundle.main.resourceURL?.appendingPathComponent("Forel_ForelApp.bundle/Resources/Resources/\(name).png"),
            Bundle.main.resourceURL?.appendingPathComponent("Forel_ForelApp.bundle/Contents/Resources/\(name).png"),
            Bundle.main.resourceURL?.appendingPathComponent("Forel_ForelApp.bundle/Contents/Resources/Resources/\(name).png"),
            Bundle.main.resourceURL?.appendingPathComponent("\(name).png"),
            Bundle.main.bundleURL.appendingPathComponent("Resources/\(name).png")
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: candidate) {
                return image
            }
        }
        return nil
    }
}
