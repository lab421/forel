// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import Foundation

extension SystemUploadTransport {
    /// Authenticates and checks read access to the configured server folder without modifying it.
    public func testConnection(configuration: UploadConfiguration, password: String?) throws {
        switch configuration.protocolType {
        case .ftp, .ftpsImplicit, .ftpsExplicit:
            try FTPUpload.testConnection(configuration: configuration, password: password)
        case .sftp:
            try SFTPUpload.testConnection(configuration: configuration, password: password)
        case .webdav, .webdavs:
            try WebDAVUpload.testConnection(configuration: configuration, password: password)
        }
    }
}
