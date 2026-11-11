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

/// Where ForelCore looks up its translated text.
///
/// In the app this is the main bundle: `build.sh` compiles
/// `Localization/Localizable.xcstrings` into `Forel.app/Contents/Resources`.
/// A `swift test` process has no such bundle, so without the catalog every
/// plural would read like "1 actions"; tests point this at a copy of the
/// catalog they compile themselves.
public enum ForelStrings {
    private static let current = OSAllocatedUnfairLock(initialState: Bundle.main)

    public static var bundle: Bundle {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

extension Bundle {
    /// The bundle for `String(localized:bundle:comment:)` in ForelCore.
    static var forelStrings: Bundle { ForelStrings.bundle }
}
