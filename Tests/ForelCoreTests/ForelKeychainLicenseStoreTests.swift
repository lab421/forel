import Foundation
import Lab421Licensing
import LocalAuthentication
import Security
import Testing
@testable import ForelCore

@Suite @MainActor struct ForelKeychainLicenseStoreTests {
    @Test func freeLaunchOnlyChecksOnceAndNeverUsesInteractiveLoad() throws {
        let fixture = Fixture()
        #expect(try fixture.store.load() == nil)
        #expect(fixture.silentReads == 1)
        #expect(try fixture.restartedStore().load() == nil)
        #expect(fixture.silentReads == 1)
        #expect(fixture.backend.interactiveReads == 0)
        #expect(fixture.backend.writes == 0)
    }

    @Test func oldTrialRecordDoesNotRequireKeychainOnLaterLaunches() throws {
        let fixture = Fixture()
        fixture.backend.record = LicenseRecord(lastObservedAt: Date(), trialIsValid: false, trialToken: "old-trial")
        #expect(try fixture.store.load() == nil)
        #expect(try fixture.restartedStore().load() == nil)
        #expect(fixture.silentReads == 1)
        #expect(fixture.backend.writes == 0)
        #expect(fixture.backend.record?.trialToken == "old-trial")
    }

    @Test func existingPaidRecordIsRestoredWithoutLosingIt() throws {
        let fixture = Fixture()
        let record = LicenseRecord(lastObservedAt: Date(), licenseKey: "PRO", licenseIsValid: true, licenseToken: "signed-token")
        fixture.backend.record = record
        #expect(try fixture.store.load() == record)
        #expect(try fixture.restartedStore().load() == record)
        #expect(fixture.silentReads == 1)
        #expect(fixture.backend.interactiveReads == 1)
    }

    @Test func activatedLicenseCanRequestAccessAfterLocalRebuild() throws {
        let fixture = Fixture()
        let record = LicenseRecord(lastObservedAt: Date(), licenseKey: "PRO", licenseIsValid: true, licenseToken: "signed-token")
        try fixture.store.save(record)
        fixture.readError = TestError.denied
        #expect(try fixture.restartedStore().load() == record)
        #expect(fixture.silentReads == 0)
        #expect(fixture.backend.interactiveReads == 1)
    }

    @Test func activatingAndReturningToFreeUpdatesStartupAccess() throws {
        let fixture = Fixture()
        #expect(try fixture.store.load() == nil)
        let record = LicenseRecord(lastObservedAt: Date(), licenseKey: "PRO", licenseIsValid: true, licenseToken: "signed-token")
        try fixture.store.save(record)
        #expect(try fixture.restartedStore().load() == record)
        let readsBeforeDeactivation = fixture.silentReads
        try fixture.store.save(LicenseRecord(lastObservedAt: Date()))
        #expect(try fixture.restartedStore().load() == nil)
        #expect(fixture.silentReads == readsBeforeDeactivation)
    }

    @Test func revokedLicenseSkipsKeychainOnRestart() throws {
        let fixture = Fixture()
        try fixture.store.save(LicenseRecord(lastObservedAt: Date(), licenseKey: "PRO", licenseIsValid: false))
        #expect(try fixture.restartedStore().load() == nil)
        #expect(fixture.silentReads == 0)
    }

    @Test func deniedAccessNeverFallsBackToInteractiveReadOrDiscardsTheRecord() throws {
        let fixture = Fixture()
        fixture.backend.record = LicenseRecord(lastObservedAt: Date(), licenseKey: "PRO", licenseIsValid: true)
        fixture.readError = TestError.denied
        #expect(throws: TestError.denied) { try fixture.store.load() }
        #expect(throws: TestError.denied) { try fixture.restartedStore().load() }
        #expect(fixture.backend.interactiveReads == 0)
        #expect(fixture.backend.writes == 0)
        fixture.readError = nil
        #expect(try fixture.restartedStore().load()?.licenseKey == "PRO")
    }

    @Test func failedSaveDoesNotMarkAnExistingPaidLicenseAsFree() throws {
        let fixture = Fixture()
        let record = LicenseRecord(lastObservedAt: Date(), licenseKey: "PRO", licenseIsValid: true)
        try fixture.store.save(record)
        fixture.backend.saveError = TestError.denied
        #expect(throws: TestError.denied) { try fixture.store.save(LicenseRecord(lastObservedAt: Date())) }
        #expect(try fixture.restartedStore().load() == record)
    }

    @Test func startupQueryForbidsAuthenticationDialogs() throws {
        let query = ForelKeychainLicenseStore.startupQuery(service: "test-service", account: "test-account")
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context.interactionNotAllowed)
        #expect(query[kSecAttrService as String] as? String == "test-service")
        #expect(query[kSecAttrAccount as String] as? String == "test-account")
    }

    @Test func loginKeychainInteractionIsDisabledDuringReadAndRestoredAfterwards() throws {
        var initial: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&initial) == errSecSuccess)
        let result = try ForelKeychainLicenseStore.withoutUserInteraction {
            var allowed: DarwinBoolean = true
            #expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
            #expect(!allowed.boolValue)
            return "saved-record"
        }
        #expect(result == "saved-record")
        var restored: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
        #expect(restored.boolValue == initial.boolValue)
    }

    @Test func loginKeychainInteractionIsRestoredAfterReadFailure() throws {
        var initial: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&initial) == errSecSuccess)
        #expect(throws: TestError.denied) {
            try ForelKeychainLicenseStore.withoutUserInteraction {
                var allowed: DarwinBoolean = true
                #expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
                #expect(!allowed.boolValue)
                throw TestError.denied
            }
        }
        var restored: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
        #expect(restored.boolValue == initial.boolValue)
    }

    @Test func fileBasedKeychainCannotPromptForUnlockOrItemAccess() throws {
        // Use an isolated file-based Keychain, never the user's login items.
        // Disable interaction for setup too, so a failing test cannot prompt.
        try ForelKeychainLicenseStore.withoutUserInteraction {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("forel-test-\(UUID().uuidString).keychain").path
            let password = UUID().uuidString
            var created: SecKeychain?
            let createStatus = password.withCString {
                SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &created)
            }
            try #require(createStatus == errSecSuccess)
            let keychain = try #require(created)
            defer { SecKeychainDelete(keychain) }

            let service = "forel.test.\(UUID().uuidString)"
            let data = Data("test-record".utf8)
            let item: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "test-account",
                kSecValueData as String: data,
                kSecUseKeychain as String: keychain,
            ]
            try #require(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
            var query = ForelKeychainLicenseStore.startupQuery(service: service, account: "test-account")
            query[kSecMatchSearchList as String] = [keychain]
            var result: CFTypeRef?
            try #require(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
            #expect(result as? Data == data)

            // Model an item belonging to a different executable/signature.
            var trusted: SecTrustedApplication?
            try #require(SecTrustedApplicationCreateFromPath("/usr/bin/false", &trusted) == errSecSuccess)
            var access: SecAccess?
            try #require(SecAccessCreate("Forel test" as CFString, [try #require(trusted)] as CFArray, &access) == errSecSuccess)
            var restrictedItem = item
            restrictedItem[kSecAttrAccount as String] = "restricted-account"
            restrictedItem[kSecAttrAccess as String] = try #require(access)
            try #require(SecItemAdd(restrictedItem as CFDictionary, nil) == errSecSuccess)
            var restrictedQuery = ForelKeychainLicenseStore.startupQuery(service: service, account: "restricted-account")
            restrictedQuery[kSecMatchSearchList as String] = [keychain]
            result = nil
            let deniedStatus = SecItemCopyMatching(restrictedQuery as CFDictionary, &result)
            #expect(deniedStatus == errSecInteractionNotAllowed || deniedStatus == errSecAuthFailed)
            #expect(result == nil)

            try #require(SecKeychainLock(keychain) == errSecSuccess)
            result = nil
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            #expect(status == errSecInteractionNotAllowed || status == errSecAuthFailed)
            #expect(result == nil)
        }
    }
}

private enum TestError: Error { case denied }

@MainActor private final class Fixture {
    private let suite = "com.lab421.forel.tests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    let backend = Backend()
    var silentReads = 0
    var readError: TestError?
    lazy var store = restartedStore()

    init() { defaults = UserDefaults(suiteName: suite)! }

    func restartedStore() -> ForelKeychainLicenseStore {
        ForelKeychainLicenseStore(service: "test", defaults: defaults, secureStore: backend) { [unowned self] in
            silentReads += 1
            if let readError { throw readError }
            return backend.record
        }
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

@MainActor private final class Backend: LicenseSecureStoring {
    var record: LicenseRecord?
    var interactiveReads = 0
    var writes = 0
    var saveError: TestError?

    func load() throws -> LicenseRecord? {
        interactiveReads += 1
        return record
    }

    func save(_ record: LicenseRecord) throws {
        if let saveError { throw saveError }
        writes += 1
        self.record = record
    }
}
