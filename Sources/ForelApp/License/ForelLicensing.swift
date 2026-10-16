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
import ForelCore

/// Wires the shared Lab421Licensing package to Forel's own identifiers: its
/// `product_id` on the license server, its Keychain service, its
/// `UserDefaults` suite, and the signing key for that server's offline
/// tokens. Other apps sharing the same license server use the same package
/// with their own values here.
enum ForelLicensing {
    static let productID = "forel"
    static let appName = "Forel"
    static let keychainService = "com.lab421.forel.license"
    static let userDefaultsSuite: String = {
        let suite = "com.lab421.forel.licensing"
        ForelLicensePreferences.migrate(to: suite, from: "com.lab421.forel", service: keychainService)
        return suite
    }()
    static let purchaseURL = URL(string: "https://forel.app")!

    static let baseURL: URL = {
        switch BuildFlavor.current {
        case .development:
            URL(string: "http://localhost:8787/api/v1/license")!
        case .adHoc, .appStore:
            URL(string: "https://api.ombrelle.app/api/v1/license")!
        }
    }()

    /// Raw 32-byte Ed25519 public key matching the `LICENSE_SIGNING_PRIVATE_KEY`
    /// secret on the license server. Rotating that key invalidates every cached
    /// token signed with the old one, forcing every device back online once.
    static let productionPublicKeyRaw = Data(
        base64Encoded: "U0CobIap9nWvOjGXe0Xg8jY37k86j1l2bJTny4GYsNI="
    )!
}
