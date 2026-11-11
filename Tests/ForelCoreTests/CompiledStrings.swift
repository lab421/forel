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
@testable import ForelCore

/// The app finds its text in its own bundle, which `build.sh` fills from
/// `Localization/Localizable.xcstrings`. A test process has no such bundle,
/// so plurals would read "1 actions": suites that check text with a count
/// call `install()` in their `init` to compile the catalog once and point
/// ForelCore at its English table, whatever the Mac's language.
enum CompiledStrings {
    static func install() {
        ForelStrings.bundle = bundle
    }

    private static let bundle: Bundle = {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = repoRoot.appendingPathComponent("Localization/Localizable.xcstrings")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("forel-strings-\(UUID().uuidString).bundle")
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcstringstool", "compile", catalog.path, "--output-directory", output.path]
        process.standardOutput = FileHandle.nullDevice
        try! process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "xcstringstool could not compile \(catalog.path)")
        return Bundle(url: output.appendingPathComponent("en.lproj"))!
    }()
}
