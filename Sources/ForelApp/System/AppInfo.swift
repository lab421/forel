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

/// App identity shown by both the "About Forel" panel and Settings → About,
/// so the two never drift apart.
enum AppInfo {
    static let name = "Forel"
    static let tagline = "Open-source file automation for macOS"
    static let repositoryURL = URL(string: "https://github.com/lab421/forel")!

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development"
    }

    /// `./build.sh dev` stamps this placeholder version; it is never a release.
    static let developmentVersion = "0.0.0-dev"

    static var isDevelopmentBuild: Bool {
        version == developmentVersion
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Development"
    }

    static var copyright: String? {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
    }
}
