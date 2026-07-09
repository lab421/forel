import Foundation
import Security
import Testing
@testable import Lab421Licensing

/// Exercises the real Keychain, unlike `LicenseManagerTests` which always
/// substitutes an in-memory `LicenseSecureStoring`. Uses a service string
/// unique to this run so it can't collide with another test run or a real
/// app, and always cleans up after itself.
@MainActor
struct KeychainLicenseStoreTests {
    @Test func savesAndLoadsARecordRoundTrip() throws {
        let service = "com.lab421.licensing.tests.\(UUID().uuidString)"
        let store = KeychainLicenseStore(service: service)
        defer { deleteKeychainItem(service: service) }

        #expect(try store.load() == nil)

        let record = LicenseRecord(
            lastObservedAt: Date(timeIntervalSince1970: 1_700_000_000),
            licenseKey: "TEST-KEY",
            licenseIsValid: true,
            lastValidatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            licenseToken: "payload.signature"
        )
        try store.save(record)
        #expect(try store.load() == record)

        // A second save exercises the update path (`SecItemUpdate`) rather
        // than the initial add — the two use different Security APIs.
        var updated = record
        updated.licenseIsValid = false
        updated.invalidReason = .licenseExpired
        try store.save(updated)
        #expect(try store.load() == updated)
    }

    @Test func differentServicesDoNotShareARecord() throws {
        let serviceA = "com.lab421.licensing.tests.\(UUID().uuidString)"
        let serviceB = "com.lab421.licensing.tests.\(UUID().uuidString)"
        defer {
            deleteKeychainItem(service: serviceA)
            deleteKeychainItem(service: serviceB)
        }

        let storeA = KeychainLicenseStore(service: serviceA)
        let storeB = KeychainLicenseStore(service: serviceB)

        try storeA.save(LicenseRecord(lastObservedAt: Date(timeIntervalSince1970: 1_700_000_000), licenseKey: "A-KEY"))

        // Two apps on the same Mac must not see each other's license.
        #expect(try storeB.load() == nil)
        #expect(try storeA.load()?.licenseKey == "A-KEY")
    }
}

private func deleteKeychainItem(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "direct-license",
    ]
    SecItemDelete(query as CFDictionary)
}
