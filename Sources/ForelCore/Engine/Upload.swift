// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import Foundation
import Security
import Darwin

public enum UploadProtocol: String, CaseIterable, Codable, Sendable {
    case ftp, ftpsImplicit = "ftps_implicit", ftpsExplicit = "ftps_explicit", sftp, webdav, webdavs
    public var label: String {
        switch self {
        case .ftp: return "FTP"
        case .ftpsImplicit: return "FTP (Implicit TLS)"
        case .ftpsExplicit: return "FTP (Explicit TLS)"
        case .sftp: return "SFTP"
        case .webdav: return "WebDAV (HTTP)"
        case .webdavs: return "WebDAV (HTTPS)"
        }
    }
    public var defaultPort: Int {
        switch self {
        case .ftp, .ftpsExplicit: return 21
        case .ftpsImplicit: return 990
        case .sftp: return 22
        case .webdav: return 80
        case .webdavs: return 443
        }
    }
}

public struct UploadServer: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var protocolType: UploadProtocol
    public var host: String
    public var port: Int?
    public var username: String
    public var identityPath: String?
    public var credentialID: String

    public init(id: String = UUID().uuidString, name: String, protocolType: UploadProtocol, host: String, port: Int? = nil, username: String, identityPath: String? = nil, credentialID: String = UUID().uuidString) {
        self.id = id; self.name = name; self.protocolType = protocolType; self.host = host
        self.port = port; self.username = username; self.identityPath = identityPath; self.credentialID = credentialID
    }

    public func resolving(action: Action) -> Action {
        var result = action
        guard case .object(var params) = action.params else { return result }
        params["upload_protocol"] = .string(protocolType.rawValue)
        params["upload_host"] = .string(host)
        params["upload_port"] = .string(port.map(String.init) ?? "")
        params["upload_username"] = .string(username)
        params["upload_identity_path"] = .string(identityPath ?? "")
        params["upload_credential_id"] = .string(credentialID)
        result.params = .object(params)
        return result
    }

    public func configuration(remotePath: String = "/", conflict: MoveConflictResolution = .replace) throws -> UploadConfiguration {
        let action = Action(ruleId: "", kind: .upload, params: .object(["upload_remote_path": .string(remotePath), ActionParam.onConflict: .string(conflict.rawValue)]), position: 0)
        return try UploadConfiguration(action: resolving(action: action))
    }
}

public struct UploadConfiguration: Sendable, Equatable {
    public let protocolType: UploadProtocol
    public let host: String
    public let port: Int
    public let username: String
    public let remotePath: String
    public let credentialID: String
    public let identityPath: String?
    public let conflict: MoveConflictResolution
    public let relativeFolders: [String]

    static func validateReference(_ action: Action) throws {
        guard let id = action.params["upload_server_id"]?.stringValue, !id.isEmpty else { throw ActionError("Choose a saved upload server") }
        _ = try validatedActionOptions(action)
    }

    private static func validatedActionOptions(_ action: Action) throws -> (String, MoveConflictResolution) {
        let remotePath = action.params["upload_remote_path"]?.stringValue ?? "/"
        guard remotePath.hasPrefix("/"), !remotePath.contains("\0"), !remotePath.contains("\n"), !remotePath.contains("\r"),
              !remotePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw ActionError("Enter an absolute server folder without . or .. components") }
        let rawConflict = action.params[ActionParam.onConflict]?.stringValue ?? MoveConflictResolution.rename.rawValue
        guard let conflict = MoveConflictResolution(rawValue: rawConflict), conflict != .discard else { throw ActionError("Invalid upload conflict policy") }
        return (remotePath, conflict)
    }

    public init(action: Action, serverLookup: (String) throws -> UploadServer?) throws {
        guard let id = action.params["upload_server_id"]?.stringValue, !id.isEmpty,
              let server = try serverLookup(id) else { throw ActionError("Choose a saved upload server; the selected server may have been deleted") }
        try self.init(action: server.resolving(action: action))
    }

    public init(action: Action) throws {
        guard let type = action.params["upload_protocol"]?.stringValue.flatMap(UploadProtocol.init(rawValue:)) else { throw ActionError("Choose an upload protocol") }
        var host = action.params["upload_host"]?.stringValue ?? ""
        guard !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !host.contains("/"), !host.contains("@"), !host.contains("?"), !host.contains("#"), !host.contains("%"), !host.contains("\0") else { throw ActionError("Enter a server hostname without a URL or credentials") }
        if host.contains(":") {
            let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
            var address = in6_addr()
            guard bare.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { throw ActionError("Enter a valid IPv6 address") }
            host = "[\(bare)]"
        } else if host.contains("[") || host.contains("]") { throw ActionError("Enter a valid server hostname") }
        let portText = action.params["upload_port"]?.stringValue ?? ""
        let port = portText.isEmpty ? type.defaultPort : (Int(portText) ?? 0)
        guard (1...65535).contains(port) else { throw ActionError("Enter a valid server port") }
        let username = action.params["upload_username"]?.stringValue ?? ""
        guard !username.isEmpty, !username.contains("\0"), !username.contains("\n"), !username.contains("\r") else { throw ActionError("Enter a valid server user name") }
        let (remotePath, conflict) = try Self.validatedActionOptions(action)
        let id = action.params["upload_credential_id"]?.stringValue ?? action.id
        guard !id.isEmpty else { throw ActionError("Upload credential identifier is missing") }
        let identity = action.params["upload_identity_path"]?.stringValue
        if let identity, !identity.isEmpty, (!identity.hasPrefix("/") || identity.contains("\0") || identity.contains("\n") || identity.contains("\r")) { throw ActionError("SSH key path must be absolute") }
        self.protocolType = type; self.host = host.lowercased(); self.port = port; self.username = username
        self.remotePath = remotePath; self.credentialID = id; self.identityPath = identity?.isEmpty == false ? identity : nil
        self.conflict = conflict
        self.relativeFolders = []
    }

    private init(copy: UploadConfiguration, relativeFolders: [String]) {
        self.protocolType = copy.protocolType; self.host = copy.host; self.port = copy.port; self.username = copy.username
        self.remotePath = copy.remotePath; self.credentialID = copy.credentialID; self.identityPath = copy.identityPath
        self.conflict = copy.conflict; self.relativeFolders = relativeFolders
    }
    func withRelativeFolders(_ folders: [String]) -> UploadConfiguration { UploadConfiguration(copy: self, relativeFolders: folders) }
    var effectiveRemotePath: String {
        let parts = [remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))] + relativeFolders
        return "/" + parts.filter { !$0.isEmpty }.joined(separator: "/")
    }
}

public enum UploadCredentials {
    private static let service = "com.lab421.forel.upload"
    private struct Record: Codable {
        let protocolType: String
        let host: String
        let port: Int
        let username: String
        let secret: String
    }
    static func encode(_ password: String, configuration: UploadConfiguration) throws -> Data {
        try JSONEncoder().encode(Record(protocolType: configuration.protocolType.rawValue, host: configuration.host,
                                       port: configuration.port, username: configuration.username, secret: password))
    }
    static func decode(_ data: Data, configuration: UploadConfiguration) throws -> String {
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { throw ActionError("Saved upload credentials are invalid; save them again") }
        guard record.protocolType == configuration.protocolType.rawValue, record.host == configuration.host,
              record.port == configuration.port, record.username == configuration.username else {
            throw ActionError("The server or user name changed; save credentials for this destination again")
        }
        return record.secret
    }
    public static func save(_ password: String, for id: String, configuration: UploadConfiguration) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
        let data = try encode(password, configuration: configuration)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw ActionError("Could not save upload credentials to Keychain (\(added))") }
        } else if status != errSecSuccess {
            throw ActionError("Could not update upload credentials in Keychain (\(status))")
        }
    }
    public static func load(for id: String, configuration: UploadConfiguration) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ActionError("Could not read upload credentials from Keychain (\(status))")
        }
        return try decode(data, configuration: configuration)
    }
    public static func delete(for id: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ActionError("Could not delete upload credentials from Keychain (\(status))") }
    }
}

public protocol UploadTransport: Sendable {
    func upload(path: String, configuration: UploadConfiguration, password: String?) throws
}

public struct SystemUploadTransport: UploadTransport {
    public init() {}
    public func upload(path: String, configuration: UploadConfiguration, password: String?) throws {
        switch configuration.protocolType {
        case .webdav, .webdavs:
            try WebDAVUpload.run(path: path, configuration: configuration, password: password)
        case .sftp:
            try SFTPUpload.run(path: path, configuration: configuration, password: password)
        case .ftp, .ftpsImplicit, .ftpsExplicit:
            try FTPUpload.run(path: path, configuration: configuration, password: password)
        }
    }
}
