import Foundation
import Security
import LocalAuthentication

/// Stores only a Keychain generic-password reference, never the secret.
public struct PasswordContentCondition: Codable, Equatable, Sendable {
    public var credentialID: String
    public var operand: String
    public init(credentialID: String = "", operand: String = "") {
        self.credentialID = credentialID; self.operand = operand
    }
    public var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    public static func decode(_ value: String) -> Self? {
        guard value.utf8.count <= 16_384, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public var referenceIsValid: Bool {
        UUID(uuidString: credentialID) != nil
    }
}

public enum PDFPasswordStore {
    private static let service = "com.lab421.forel.pdf-password"
    public static func save(_ password: String, for id: String) throws {
        guard UUID(uuidString: id) != nil, !password.isEmpty else { throw ActionError("Enter a PDF password") }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id]
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ActionError("Could not save PDF password in Keychain") }
        } else if status != errSecSuccess { throw ActionError("Could not save PDF password in Keychain") }
    }
    public static func remove(for id: String) throws {
        guard UUID(uuidString: id) != nil else { return }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ActionError("Could not remove PDF password from Keychain") }
    }
    static func password(for id: String) -> String? {
        guard UUID(uuidString: id) != nil else { return nil }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: id, kSecReturnData: true,
                                      kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationContext: context]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
