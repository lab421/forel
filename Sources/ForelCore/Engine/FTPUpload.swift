// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import Foundation
import Darwin

/// FTP(S) uploads through macOS curl. Credentials are supplied over a pipe,
/// never in the URL, command-line arguments, or a persistent configuration.
enum FTPUpload {
    static func testConnection(configuration: UploadConfiguration, password: String?, testCAPath: String? = nil) throws {
        let credential = try curlCredential(configuration.username, password: password)
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/%?#")
        let parts = try configuration.effectiveRemotePath.split(separator: "/").map { part -> String in
            guard part != ".", part != "..", let encoded = String(part).addingPercentEncoding(withAllowedCharacters: allowed) else { throw ActionError("Invalid FTP path") }
            return encoded
        }.joined(separator: "/")
        var url = URLComponents()
        url.scheme = configuration.protocolType == .ftpsImplicit ? "ftps" : "ftp"
        url.host = configuration.host; url.port = configuration.port
        url.percentEncodedPath = "//" + parts + (parts.isEmpty ? "" : "/")
        guard let address = url.url else { throw ActionError("Invalid FTP server address") }
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var options = ["-q", "--silent", "--fail", "--noproxy", "*", "--connect-timeout", "15", "--max-time", "20", "--config", "-"]
        if configuration.protocolType == .ftpsExplicit { options.append("--ssl-reqd") }
        if let testCAPath { options += ["--cacert", testCAPath] }
        task.arguments = options + [address.absoluteString]
        let input = Pipe(); task.standardInput = input
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { throw ActionError("Cannot start FTP connection test") }
        do { try input.fileHandleForWriting.write(contentsOf: credential); try input.fileHandleForWriting.close() }
        catch { if task.isRunning { task.terminate() }; task.waitUntilExit(); throw ActionError("Cannot provide FTP credentials") }
        let deadline = Date().addingTimeInterval(20)
        while task.isRunning {
            if Task<Never, Never>.isCancelled || Date() >= deadline {
                task.terminate(); Thread.sleep(forTimeInterval: 0.1)
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                task.waitUntilExit()
                throw ActionError(Task<Never, Never>.isCancelled ? "Connection test was cancelled" : "Connection test timed out")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        task.waitUntilExit()
        guard task.terminationReason == .exit && task.terminationStatus == 0 else { throw ActionError("FTP connection test failed; check the server, credentials, and folder") }
    }
    static func run(path: String, configuration: UploadConfiguration, password: String?, testCAPath: String? = nil) throws {
        guard configuration.conflict == .replace else {
            throw ActionError("This FTP server cannot guarantee a safe no-overwrite upload; choose Replace or use SFTP/WebDAV")
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let attrs = try fm.attributesOfItem(atPath: path)
        guard let type = attrs[.type] as? FileAttributeType, type == .typeRegular || type == .typeDirectory else { throw ActionError("Only regular files and folders can be uploaded") }
        let localFiles = try UploadLocalFiles(path: root.path, directory: type == .typeDirectory)
        var entries: [(URL, String, Bool)] = []
        if type == .typeDirectory {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { throw ActionError("Cannot read upload folder") }
            for case let child as URL in enumerator {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw ActionError("The folder contains a symbolic link or unsupported item") }
                let childPath = child.standardizedFileURL.path
                guard childPath.hasPrefix(root.path + "/") else { throw ActionError("An upload item is outside its folder") }
                entries.append((child, String(childPath.dropFirst(root.path.count + 1)), values.isDirectory == true))
            }
        }
        let name = root.lastPathComponent
        guard !name.isEmpty else { throw ActionError("Cannot upload the filesystem root") }
        let allNames = [name] + entries.map(\.1)
        guard allNames.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }) else { throw ActionError("FTP does not support these file names") }
        let credential = try curlCredential(configuration.username, password: password)
        func url(_ relative: String, directory: Bool = false) throws -> URL {
            let components = (configuration.effectiveRemotePath + "/" + relative).split(separator: "/", omittingEmptySubsequences: true)
            var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/%?#")
            let parts = try components.map { component -> String in
                guard component != ".", component != "..", let value = String(component).addingPercentEncoding(withAllowedCharacters: allowed) else { throw ActionError("Invalid FTP path") }
                return value
            }.joined(separator: "/")
            var result = URLComponents()
            result.scheme = configuration.protocolType == .ftpsImplicit ? "ftps" : "ftp"
            result.host = configuration.host; result.port = configuration.port
            // A doubled slash means an absolute server path for curl's FTP URL.
            result.percentEncodedPath = "//" + parts + (directory ? "/" : "")
            guard let value = result.url else { throw ActionError("Invalid FTP server address") }
            return value
        }
        func invoke(_ arguments: [String]) throws {
            if Task<Never, Never>.isCancelled { throw ActionError("FTP upload was cancelled") }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            var options = ["-q", "--silent", "--fail", "--noproxy", "*", "--connect-timeout", "20", "--max-time", "3600", "--config", "-"]
            if !configuration.relativeFolders.isEmpty { options.append("--ftp-create-dirs") }
            if configuration.protocolType == .ftpsExplicit { options.append("--ssl-reqd") }
            if let testCAPath { options += ["--cacert", testCAPath] }
            task.arguments = options + arguments
            let input = Pipe(); task.standardInput = input
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { throw ActionError("Cannot start FTP transport") }
            do { try input.fileHandleForWriting.write(contentsOf: credential); try input.fileHandleForWriting.close() }
            catch { if task.isRunning { task.terminate() }; task.waitUntilExit(); throw ActionError("Cannot provide FTP credentials") }
            let deadline = Date().addingTimeInterval(3600)
            while task.isRunning {
                if Task<Never, Never>.isCancelled || Date() >= deadline {
                    task.terminate(); Thread.sleep(forTimeInterval: 0.1)
                    if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                    task.waitUntilExit()
                    throw ActionError(Task<Never, Never>.isCancelled ? "FTP upload was cancelled" : "FTP upload timed out")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            task.waitUntilExit()
            guard task.terminationReason == .exit && task.terminationStatus == 0 else { throw ActionError("FTP transfer failed (code \(task.terminationStatus))") }
        }
        if type == .typeRegular {
            try localFiles.withSnapshot(nil) { try invoke(["--upload-file", $0.path, try url(name).absoluteString]) }
            return
        }
        // MKD is exclusive. Refuse to merge into or delete a pre-existing
        // folder even when Replace is selected; that requires a server-specific
        // recursive delete and is not safely representable by FTP.
        let remoteBase = configuration.effectiveRemotePath == "/" ? "/" + name : configuration.effectiveRemotePath + "/" + name
        let rootURL = try url("", directory: true)
        if !configuration.relativeFolders.isEmpty { try invoke(["--head", rootURL.absoluteString]) }
        try invoke(["--quote", "MKD \(remoteBase)", "--head", rootURL.absoluteString])
        for (_, relative, directory) in entries {
            if directory {
                try invoke(["--quote", "MKD \(remoteBase)/\(relative)", "--head", rootURL.absoluteString])
            } else {
                try localFiles.withSnapshot(relative) { try invoke(["--upload-file", $0.path, try url(name + "/" + relative).absoluteString]) }
            }
        }
    }

    private static func curlCredential(_ username: String, password: String?) throws -> Data {
        guard !username.contains(":"), let password, !password.contains("\0"), !password.contains("\n"), !password.contains("\r") else {
            throw ActionError("FTP requires a saved password and a user name without a colon")
        }
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        return Data("user = \"\(escape(username)):\(escape(password))\"\n".utf8)
    }
}
