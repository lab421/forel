// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import Foundation
import Darwin

/// SFTP v3 over the system SSH client. Requests are encoded directly so the
/// client can request exclusive creation and publish using hard links when
/// supported, avoiding an overwriting rename for no-clobber policies.
enum SFTPUpload {
    private struct Packet {
        var data = Data()
        mutating func byte(_ v: UInt8) { data.append(v) }
        mutating func u32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
        mutating func u64(_ v: UInt64) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
        mutating func bytes(_ v: Data) { u32(UInt32(v.count)); data.append(v) }
        mutating func string(_ v: String) { bytes(Data(v.utf8)) }
    }
    private struct Reader {
        let data: Data
        var index = 0
        mutating func byte() throws -> UInt8 {
            guard index < data.count else { throw ActionError("Invalid SFTP response") }
            defer { index += 1 }; return data[index]
        }
        mutating func u32() throws -> UInt32 {
            guard index <= data.count - 4 else { throw ActionError("Invalid SFTP response") }
            var value: UInt32 = 0
            for _ in 0..<4 { value = (value << 8) | UInt32(try byte()) }
            return value
        }
        mutating func bytes() throws -> Data {
            let length = Int(try u32())
            guard length <= data.count - index else { throw ActionError("Invalid SFTP response") }
            defer { index += length }; return data.subdata(in: index..<(index + length))
        }
        mutating func string() throws -> String {
            guard let value = String(data: try bytes(), encoding: .utf8) else { throw ActionError("Invalid SFTP response") }
            return value
        }
    }
    private final class Connection {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let deadline: Date?
        var nextID: UInt32 = 1
        var posixRename = false
        var hardlink = false
        init(process: Process, input: FileHandle, output: FileHandle, deadline: Date? = nil) throws {
            self.process = process; self.input = input; self.output = output
            self.deadline = deadline
            let flags = fcntl(input.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(input.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ActionError("Cannot configure SFTP connection") }
            var hello = Packet(); hello.byte(1); hello.u32(3)
            try send(hello.data)
            var response = Reader(data: try receive())
            guard try response.byte() == 2, try response.u32() >= 3 else { throw ActionError("SFTP server does not support version 3") }
            while response.index < response.data.count {
                let name = try response.string(), value = try response.bytes()
                if name == "posix-rename@openssh.com" && value == Data("1".utf8) { posixRename = true }
                if name == "hardlink@openssh.com" && value == Data("1".utf8) { hardlink = true }
            }
        }
        func send(_ data: Data) throws {
            guard data.count <= 131_072 else { throw ActionError("SFTP request is too large") }
            var header = Packet(); header.u32(UInt32(data.count)); header.data.append(data)
            let deadline = self.deadline ?? Date().addingTimeInterval(60)
            var offset = 0
            while offset < header.data.count {
                if Task<Never, Never>.isCancelled { throw ActionError("SFTP upload was cancelled") }
                if Date() >= deadline { throw ActionError("SFTP server timed out") }
                var descriptor = pollfd(fd: input.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, 200)
                if ready < 0 { if errno == EINTR { continue }; throw ActionError("SFTP connection failed") }
                if ready == 0 { continue }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw ActionError("SFTP connection closed while sending data") }
                let end = min(offset + 512, header.data.count)
                do { try input.write(contentsOf: header.data.subdata(in: offset..<end)); offset = end }
                catch {
                    let error = error as NSError
                    if error.domain == NSPOSIXErrorDomain && [EAGAIN, EINTR].contains(Int32(error.code)) { continue }
                    throw ActionError("SFTP connection closed while sending data")
                }
            }
        }
        func readExactly(_ count: Int) throws -> Data {
            var result = Data(); let deadline = self.deadline ?? Date().addingTimeInterval(60)
            while result.count < count {
                if Task<Never, Never>.isCancelled { throw ActionError("SFTP upload was cancelled") }
                if Date() >= deadline { throw ActionError("SFTP server timed out") }
                var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 200)
                if ready < 0 { if errno == EINTR { continue }; throw ActionError("SFTP connection failed") }
                if ready == 0 { continue }
                let maxRead = min(count - result.count, 32_768)
                var bytes = [UInt8](repeating: 0, count: maxRead)
                let readCount = Darwin.read(output.fileDescriptor, &bytes, maxRead)
                guard readCount > 0 else { throw ActionError("SFTP connection closed; check credentials and trusted host key") }
                result.append(contentsOf: bytes.prefix(readCount))
            }
            return result
        }
        func receive() throws -> Data {
            var header = Reader(data: try readExactly(4))
            let length = Int(try header.u32())
            guard length > 0, length <= 16 * 1024 * 1024 else { throw ActionError("Invalid SFTP packet size") }
            return try readExactly(length)
        }
        func request(_ type: UInt8, _ build: (inout Packet) -> Void) throws -> (UInt8, Reader) {
            let id = nextID; nextID &+= 1
            var packet = Packet(); packet.byte(type); packet.u32(id); build(&packet)
            try send(packet.data)
            var response = Reader(data: try receive())
            let kind = try response.byte()
            guard try response.u32() == id else { throw ActionError("Unexpected SFTP response") }
            return (kind, response)
        }
        func status(_ type: UInt8, _ build: (inout Packet) -> Void) throws -> UInt32 {
            var (kind, response) = try request(type, build)
            guard kind == 101 else { throw ActionError("Unexpected SFTP response") }
            return try response.u32()
        }
        func exists(_ path: String) throws -> Bool {
            var (kind, response) = try request(7) { $0.string(path) } // LSTAT
            if kind == 105 { return true }
            guard kind == 101 else { throw ActionError("Unexpected SFTP response") }
            let code = try response.u32()
            if code == 2 { return false }
            throw ActionError("SFTP could not inspect the destination (status \(code))")
        }
        func checkDirectory(_ path: String) throws {
            var (kind, response) = try request(11) { $0.string(path) } // OPENDIR
            guard kind == 102 else { throw ActionError("SFTP could not open the server folder") }
            let handle = try response.bytes()
            guard !handle.isEmpty, handle.count <= 16_384 else { throw ActionError("Invalid SFTP directory handle") }
            guard try status(4, { $0.bytes(handle) }) == 0 else { throw ActionError("SFTP could not close the server folder") }
        }
        func mkdir(_ path: String) throws {
            let code = try mkdirStatus(path)
            guard code == 0 else { throw ActionError("SFTP could not create a folder (status \(code))") }
        }
        func mkdirStatus(_ path: String) throws -> UInt32 { try status(14) { $0.string(path); $0.u32(0) } }
        func link(_ source: String, _ target: String) throws -> UInt32 {
            guard hardlink else { throw ActionError("The SFTP server cannot safely avoid overwriting an existing file") }
            return try status(200) { $0.string("hardlink@openssh.com"); $0.string(source); $0.string(target) }
        }
        func remove(_ path: String, directory: Bool) throws {
            let code = try status(directory ? 15 : 13) { $0.string(path) }
            guard code == 0 else { throw ActionError("SFTP could not remove a temporary item (status \(code))") }
        }
        func rename(_ source: String, _ target: String, replace: Bool) throws -> UInt32 {
            if replace && posixRename {
                return try status(200) { $0.string("posix-rename@openssh.com"); $0.string(source); $0.string(target) }
            }
            if replace {
                if try exists(target) { throw ActionError("The SFTP server cannot safely replace an existing destination") }
            }
            return try status(18) { $0.string(source); $0.string(target) }
        }
        func put(_ local: URL, _ remote: String, didCreate: () -> Void) throws {
            var (kind, response) = try request(3) { $0.string(remote); $0.u32(0x00000002 | 0x00000008 | 0x00000020); $0.u32(0) }
            guard kind == 102 else { throw ActionError("SFTP could not create a temporary file") }
            let handle = try response.bytes()
            guard !handle.isEmpty, handle.count <= 16_384 else { throw ActionError("Invalid SFTP file handle") }
            didCreate()
            let file = try FileHandle(forReadingFrom: local)
            defer { try? file.close() }
            var offset: UInt64 = 0
            do {
                while let chunk = try file.read(upToCount: 32_768), !chunk.isEmpty {
                    let code = try status(6) { $0.bytes(handle); $0.u64(offset); $0.bytes(chunk) }
                    guard code == 0 else { throw ActionError("SFTP upload failed (status \(code))") }
                    offset += UInt64(chunk.count)
                }
                let code = try status(4) { $0.bytes(handle) }
                guard code == 0 else { throw ActionError("SFTP could not finish the upload") }
            } catch {
                _ = try? status(4) { $0.bytes(handle) }
                throw error
            }
        }
    }

    static func testConnection(configuration: UploadConfiguration, password: String?,
                               sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                               testEnvironment: [String: String] = [:], knownHostsPath: String? = nil) throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("forel-sftp-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let sshConfig = directory.appendingPathComponent("config")
        let host = configuration.host.hasPrefix("[") ? String(configuration.host.dropFirst().dropLast()) : configuration.host
        var settings = "Host forel-upload\n  HostName \(quoted(host))\n  User \(quoted(configuration.username))\n  Port \(configuration.port)\n  StrictHostKeyChecking yes\n  UpdateHostKeys no\n  ConnectTimeout 15\n  NumberOfPasswordPrompts 1\n  BatchMode no\n"
        if let knownHostsPath { settings += "  UserKnownHostsFile \(quoted(knownHostsPath))\n  GlobalKnownHostsFile /dev/null\n" }
        if let identity = configuration.identityPath { settings += "  IdentityFile \(quoted(identity))\n  IdentitiesOnly yes\n" }
        try Data(settings.utf8).write(to: sshConfig, options: .atomic)
        let process = Process(); process.executableURL = sshExecutable
        process.arguments = ["-F", sshConfig.path, "-s", "forel-upload", "sftp"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.merge(testEnvironment) { _, value in value }
        if let password {
            let secret = directory.appendingPathComponent("secret")
            try Data(password.utf8).write(to: secret, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
            let helper = directory.appendingPathComponent("askpass")
            try Data("#!/bin/sh\nexec /bin/cat \"$FOREL_SFTP_SECRET_PATH\"\n".utf8).write(to: helper, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            environment["SSH_ASKPASS"] = helper.path; environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "forel"; environment["FOREL_SFTP_SECRET_PATH"] = secret.path
        }
        process.environment = environment
        do { try process.run() } catch { throw ActionError("Cannot start SFTP connection test") }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate(); Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        do {
            let connection = try Connection(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading, deadline: Date().addingTimeInterval(20))
            try connection.checkDirectory(configuration.effectiveRemotePath)
        } catch {
            if Task<Never, Never>.isCancelled { throw ActionError("Connection test was cancelled") }
            throw ActionError("SFTP connection test failed; check the server, credentials, trusted host key, and folder")
        }
    }

    static func run(path: String, configuration: UploadConfiguration, password: String?,
                    sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), testEnvironment: [String: String] = [:], knownHostsPath: String? = nil) throws {
        guard !configuration.username.contains("\r"), !configuration.username.contains("\n"), !configuration.username.contains("\0") else { throw ActionError("Invalid SFTP user name") }
        let manager = FileManager.default
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let attrs = try manager.attributesOfItem(atPath: path)
        guard let type = attrs[.type] as? FileAttributeType, type == .typeRegular || type == .typeDirectory else { throw ActionError("Only regular files and folders can be uploaded") }
        let localFiles = try UploadLocalFiles(path: root.path, directory: type == .typeDirectory)
        var entries: [(URL, String, Bool)] = []
        if type == .typeDirectory {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { throw ActionError("Cannot read upload folder") }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw ActionError("The folder contains a symbolic link or unsupported item") }
                let child = url.standardizedFileURL.path
                guard child.hasPrefix(root.path + "/") else { throw ActionError("An upload item is outside its folder") }
                entries.append((url, String(child.dropFirst(root.path.count + 1)), values.isDirectory == true))
            }
        }
        let directory = manager.temporaryDirectory.appendingPathComponent("forel-sftp-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let sshConfig = directory.appendingPathComponent("config")
        let host = configuration.host.hasPrefix("[") ? String(configuration.host.dropFirst().dropLast()) : configuration.host
        var settings = "Host forel-upload\n  HostName \(quoted(host))\n  User \(quoted(configuration.username))\n  Port \(configuration.port)\n  StrictHostKeyChecking yes\n  UpdateHostKeys no\n  ConnectTimeout 15\n  NumberOfPasswordPrompts 1\n  BatchMode no\n"
        if let knownHostsPath { settings += "  UserKnownHostsFile \(quoted(knownHostsPath))\n  GlobalKnownHostsFile /dev/null\n" }
        if let identity = configuration.identityPath { settings += "  IdentityFile \(quoted(identity))\n  IdentitiesOnly yes\n" }
        try Data(settings.utf8).write(to: sshConfig, options: .atomic)
        let process = Process()
        process.executableURL = sshExecutable
        process.arguments = ["-F", sshConfig.path, "-s", "forel-upload", "sftp"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.merge(testEnvironment) { _, value in value }
        if let password {
            let secret = directory.appendingPathComponent("secret")
            try Data(password.utf8).write(to: secret, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
            let helper = directory.appendingPathComponent("askpass")
            try Data("#!/bin/sh\nexec /bin/cat \"$FOREL_SFTP_SECRET_PATH\"\n".utf8).write(to: helper, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            environment["SSH_ASKPASS"] = helper.path; environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "forel"; environment["FOREL_SFTP_SECRET_PATH"] = secret.path
        }
        process.environment = environment
        do { try process.run() } catch { throw ActionError("Cannot start SSH: \(error.localizedDescription)") }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        let connection = try Connection(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
        var folder = configuration.remotePath == "/" ? "" : configuration.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for component in configuration.relativeFolders {
            folder += (folder.isEmpty ? "" : "/") + component
            let remote = "/" + folder
            let code = try connection.mkdirStatus(remote)
            if code != 0, try !connection.exists(remote) { throw ActionError("SFTP could not create upload folder (status \(code))") }
        }
        let base = folder
        let parent = "/" + base
        let prefix = parent == "/" ? "/" : parent + "/"
        let temporary = prefix + ".forel-upload-" + UUID().uuidString
        var cleanup: [(String, Bool)] = []
        defer { for (item, isDirectory) in cleanup.reversed() { try? connection.remove(item, directory: isDirectory) } }
        let name = root.lastPathComponent
        guard !name.isEmpty else { throw ActionError("Cannot upload the filesystem root") }
        let ext = root.pathExtension
        let stem = ext.isEmpty || type == .typeDirectory ? name : root.deletingPathExtension().lastPathComponent
        func candidate(_ index: Int) -> String {
            index == 0 ? name : "\(stem) \(index)" + ((ext.isEmpty || type == .typeDirectory) ? "" : ".\(ext)")
        }
        if type == .typeDirectory && configuration.conflict != .replace {
            for index in 0...10_000 {
                let target = prefix + candidate(index)
                let code = try connection.mkdirStatus(target)
                if code == 0 {
                    cleanup.append((target, true))
                    for (_, relative, isDirectory) in entries {
                        let destination = target + "/" + relative
                        if isDirectory { try connection.mkdir(destination); cleanup.append((destination, true)) }
                        else { try localFiles.withSnapshot(relative) { snapshot in try connection.put(snapshot, destination) { cleanup.append((destination, false)) } } }
                    }
                    cleanup.removeAll()
                    return
                }
                guard try connection.exists(target) else { throw ActionError("SFTP could not create the destination folder (status \(code))") }
                if configuration.conflict == .skip { return }
            }
            throw ActionError("Could not find an unused SFTP destination name")
        }
        if type == .typeRegular && configuration.conflict != .replace && !connection.hardlink {
            // Standard v3 servers can create the final name exclusively even
            // when they cannot atomically publish a staged hard link. An
            // interrupted transfer may leave a partial file at that name.
            for index in 0...10_000 {
                let target = prefix + candidate(index)
                if try connection.exists(target) {
                    if configuration.conflict == .skip { return }
                    continue
                }
                var created = false
                do {
                    try localFiles.withSnapshot(nil) { snapshot in try connection.put(snapshot, target) { created = true } }
                    return
                } catch {
                    if created { throw ActionError("SFTP upload failed after creating the destination; a partial remote file may remain") }
                    if try connection.exists(target) {
                        if configuration.conflict == .skip { return }
                        continue
                    }
                    throw error
                }
            }
            throw ActionError("Could not find an unused SFTP destination name")
        }
        if type == .typeDirectory {
            try connection.mkdir(temporary); cleanup.append((temporary, true))
            for (_, relative, isDirectory) in entries {
                let destination = temporary + "/" + relative
                if isDirectory { try connection.mkdir(destination); cleanup.append((destination, true)) }
                else { try localFiles.withSnapshot(relative) { snapshot in try connection.put(snapshot, destination) { cleanup.append((destination, false)) } } }
            }
        } else {
            try localFiles.withSnapshot(nil) { snapshot in try connection.put(snapshot, temporary) { cleanup.append((temporary, false)) } }
        }
        for index in 0...10_000 {
            let target = prefix + candidate(index)
            let code = configuration.conflict == .replace
                ? try connection.rename(temporary, target, replace: true)
                : try connection.link(temporary, target)
            if code == 0 {
                if configuration.conflict == .replace { cleanup.removeAll() }
                return
            }
            guard configuration.conflict != .replace, try connection.exists(target) else { throw ActionError("SFTP could not publish the upload (status \(code))") }
            if configuration.conflict == .skip { return }
        }
        throw ActionError("Could not find an unused SFTP destination name")
    }
}
