import Foundation
import Testing
@testable import Lab421Licensing

struct HardwareDeviceIdentifierProviderTests {
    @Test func deviceIDIsStableAndNonEmpty() {
        let suiteName = "com.lab421.licensing.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let provider = HardwareDeviceIdentifierProvider(userDefaultsSuiteName: suiteName)

        let first = provider.deviceID
        let second = provider.deviceID

        #expect(!first.isEmpty)
        // Same machine, same provider: two reads must agree, whether the ID
        // comes from IOKit's hardware UUID or (on an environment without
        // one) the persisted random fallback.
        #expect(first == second)
    }

    @Test func twoProvidersOnTheSameMachineAgree() {
        let suiteNameA = "com.lab421.licensing.tests.\(UUID().uuidString)"
        let suiteNameB = "com.lab421.licensing.tests.\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: suiteNameA)
            UserDefaults().removePersistentDomain(forName: suiteNameB)
        }

        let providerA = HardwareDeviceIdentifierProvider(userDefaultsSuiteName: suiteNameA)
        let providerB = HardwareDeviceIdentifierProvider(userDefaultsSuiteName: suiteNameB)

        // Both resolve the same real hardware identifier (IOPlatformUUID or
        // serial), independent of which UserDefaults suite each was given —
        // that suite is only ever consulted for the random-fallback path.
        #expect(providerA.deviceID == providerB.deviceID)
    }
}
