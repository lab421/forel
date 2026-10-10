import Foundation
import Lab421Licensing
import LocalAuthentication
import Security

/// Free launches skip the Keychain once we know no paid license is saved.
/// Legacy records are discovered without prompting. A previously activated
/// Pro license can request access again after the app's signature changes.
@MainActor
public final class ForelKeychainLicenseStore: LicenseSecureStoring {
    private let defaults: UserDefaults
    private let presenceKey: String
    private let secureStore: any LicenseSecureStoring
    private let loadWithoutPrompt: () throws -> LicenseRecord?

    public convenience init(service: String, account: String = "direct-license", userDefaultsSuiteName: String) {
        self.init(
            service: service,
            account: account,
            defaults: UserDefaults(suiteName: userDefaultsSuiteName) ?? .standard,
            secureStore: KeychainLicenseStore(service: service, account: account),
            loadWithoutPrompt: { try Self.readWithoutPrompt(service: service, account: account) }
        )
    }

    init(service: String, account: String = "direct-license", defaults: UserDefaults,
         secureStore: any LicenseSecureStoring, loadWithoutPrompt: @escaping () throws -> LicenseRecord?) {
        self.defaults = defaults
        presenceKey = "\(service).\(account).hasPaidLicense"
        self.secureStore = secureStore
        self.loadWithoutPrompt = loadWithoutPrompt
    }

    public func load() throws -> LicenseRecord? {
        let hasSavedLicense = defaults.object(forKey: presenceKey) as? Bool
        if hasSavedLicense == false { return nil }
        // Only a known paid license may prompt for access. The file-based
        // Keychain can require new authorization after an ad-hoc rebuild.
        // Migration from an old trial must remain silent.
        let record = try hasSavedLicense == true ? secureStore.load() : loadWithoutPrompt()
        let hasPaidLicense = Self.hasPaidLicense(record)
        defaults.set(hasPaidLicense, forKey: presenceKey)
        return hasPaidLicense ? record : nil
    }

    public func save(_ record: LicenseRecord) throws {
        try secureStore.save(record)
        defaults.set(Self.hasPaidLicense(record), forKey: presenceKey)
    }

    private static func hasPaidLicense(_ record: LicenseRecord?) -> Bool {
        guard let key = record?.licenseKey, !key.isEmpty else { return false }
        return record?.licenseIsValid != false
    }

    private static func readWithoutPrompt(service: String, account: String) throws -> LicenseRecord? {
        let query = startupQuery(service: service, account: account)
        var result: CFTypeRef?
        let status = try withoutUserInteraction {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ReadError(status: status)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LicenseRecord.self, from: data)
    }

    static func startupQuery(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    static func withoutUserInteraction<T>(_ operation: () throws -> T) throws -> T {
        // LAContext only suppresses authentication for the data-protection
        // Keychain. The file-based login Keychain used by KeychainLicenseStore
        // still needs this legacy API (see Chromium's FB16959400 workaround).
        // Keep the synchronous read on MainActor and restore the previous
        // setting before an explicit activation can access the Keychain.
        var wasAllowed: DarwinBoolean = false
        let getStatus = SecKeychainGetUserInteractionAllowed(&wasAllowed)
        guard getStatus == errSecSuccess else { throw ReadError(status: getStatus) }
        let setStatus = SecKeychainSetUserInteractionAllowed(false)
        guard setStatus == errSecSuccess else { throw ReadError(status: setStatus) }
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return try operation()
    }

    private struct ReadError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
                return "Activate your Pro license again in License settings to allow access to its saved Keychain record."
            }
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }
}
