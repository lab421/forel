import Foundation
import Testing
@testable import ForelCore

@Suite struct ForelLicensePreferencesTests {
    @Test(arguments: [false, true])
    func migrationPreservesFreeAndPaidStartupHintsAndDeviceIdentity(hasPaidLicense: Bool) throws {
        let legacy = "forel.preferences.legacy.\(UUID().uuidString)"
        let suite = "forel.preferences.new.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: legacy)
            defaults.removePersistentDomain(forName: suite)
        }
        let presenceKey = "test-service.direct-license.hasPaidLicense"
        UserDefaults.standard.setPersistentDomain([
            presenceKey: hasPaidLicense,
            "device.fallbackIdentifier": "existing-device-id",
            "unrelated-setting": "keep-in-original-domain",
        ], forName: legacy)

        ForelLicensePreferences.migrate(to: suite, from: legacy, service: "test-service")
        #expect(defaults.object(forKey: presenceKey) as? Bool == hasPaidLicense)
        #expect(defaults.string(forKey: "device.fallbackIdentifier") == "existing-device-id")
        #expect(defaults.object(forKey: "unrelated-setting") == nil)
        #expect(UserDefaults.standard.persistentDomain(forName: legacy)?[presenceKey] as? Bool == hasPaidLicense)

        // Deactivation or a new device identity in the new suite must take
        // precedence over stale values on the following launch.
        defaults.set(!hasPaidLicense, forKey: presenceKey)
        defaults.set("new-device-id", forKey: "device.fallbackIdentifier")
        ForelLicensePreferences.migrate(to: suite, from: legacy, service: "test-service")
        #expect(defaults.object(forKey: presenceKey) as? Bool == !hasPaidLicense)
        #expect(defaults.string(forKey: "device.fallbackIdentifier") == "new-device-id")
    }
}
