// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import Foundation

enum WebDAVUpload {
    private final class Response: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: (HTTPURLResponse?, Error?) = (nil, nil)
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
        // Response bodies are not needed; streaming and discarding avoids unbounded buffering.
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {}
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); value = (task.response as? HTTPURLResponse, error); lock.unlock(); done.signal()
        }
        func get() -> (HTTPURLResponse?, Error?) { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func testConnection(configuration: UploadConfiguration, password: String?) throws {
        guard !configuration.username.contains(":") else { throw ActionError("WebDAV user names cannot contain a colon") }
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/%?#")
        let path = try configuration.effectiveRemotePath.split(separator: "/").map { part -> String in
            guard part != ".", part != "..", let encoded = String(part).addingPercentEncoding(withAllowedCharacters: allowed) else { throw ActionError("Invalid WebDAV path") }
            return encoded
        }.joined(separator: "/")
        var components = URLComponents()
        components.scheme = configuration.protocolType == .webdavs ? "https" : "http"
        components.host = configuration.host; components.port = configuration.port
        components.percentEncodedPath = "/" + path + (path.isEmpty ? "" : "/")
        guard let url = components.url else { throw ActionError("Invalid WebDAV server address") }
        var request = URLRequest(url: url); request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        if let password {
            request.setValue("Basic " + Data("\(configuration.username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        let result = Response(), session = URLSession(configuration: config, delegate: result, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request); task.resume()
        let deadline = Date().addingTimeInterval(20)
        while result.done.wait(timeout: .now() + 0.2) == .timedOut {
            if Task<Never, Never>.isCancelled { task.cancel(); throw ActionError("Connection test was cancelled") }
            if Date() >= deadline { task.cancel(); throw ActionError("Connection test timed out") }
        }
        if Task<Never, Never>.isCancelled { throw ActionError("Connection test was cancelled") }
        let (response, error) = result.get()
        guard error == nil, let response, [200, 207].contains(response.statusCode) else {
            throw ActionError("WebDAV connection test failed; check the server, credentials, and folder")
        }
    }

    static func run(path: String, configuration: UploadConfiguration, password: String?) throws {
        guard !configuration.username.contains(":") else { throw ActionError("WebDAV user names cannot contain a colon") }
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let rootAttributes = try fileManager.attributesOfItem(atPath: path)
        guard let type = rootAttributes[.type] as? FileAttributeType, type == .typeRegular || type == .typeDirectory else {
            throw ActionError("Only regular files and folders can be uploaded")
        }
        let localFiles = try UploadLocalFiles(path: rootURL.path, directory: type == .typeDirectory)
        var entries: [(URL, String, Bool)] = []
        if type == .typeDirectory {
            guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: []) else {
                throw ActionError("Cannot read the folder to upload")
            }
            for case let child as URL in enumerator {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                    throw ActionError("The folder contains a symbolic link or unsupported item")
                }
                let rootPath = rootURL.path
                let childPath = child.standardizedFileURL.path
                guard childPath.hasPrefix(rootPath + "/") else { throw ActionError("The folder contains an item outside its root") }
                let relative = String(childPath.dropFirst(rootPath.count + 1))
                entries.append((child, relative, values.isDirectory == true))
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        let name = rootURL.lastPathComponent
        guard !name.isEmpty else { throw ActionError("Cannot upload the filesystem root") }
        func makeURL(_ relative: String) throws -> URL {
            let components = (configuration.remotePath + "/" + relative).split(separator: "/", omittingEmptySubsequences: true)
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/%?#")
            let encoded = try components.map { part -> String in
                guard part != ".", part != "..", let value = String(part).addingPercentEncoding(withAllowedCharacters: allowed) else {
                    throw ActionError("Invalid remote path")
                }
                return value
            }.joined(separator: "/")
            var url = URLComponents()
            url.scheme = configuration.protocolType == .webdavs ? "https" : "http"
            url.host = configuration.host
            url.port = configuration.port
            url.percentEncodedPath = "/" + encoded
            guard let value = url.url else { throw ActionError("Invalid WebDAV server address") }
            return value
        }
        func request(_ method: String, url: URL, file: URL? = nil, headers: [String: String] = [:]) throws -> Int {
            if Task<Never, Never>.isCancelled { throw ActionError("WebDAV upload was cancelled") }
            var request = URLRequest(url: url)
            request.httpMethod = method
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            if let password {
                let token = Data("\(configuration.username):\(password)".utf8).base64EncodedString()
                request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            }
            let result = Response()
            let session = URLSession(configuration: config, delegate: result, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let task = file.map { session.uploadTask(with: request, fromFile: $0) }
                ?? session.dataTask(with: request)
            task.resume()
            let deadline = Date().addingTimeInterval(3600)
            while result.done.wait(timeout: .now() + 0.2) == .timedOut {
                if Task<Never, Never>.isCancelled { task.cancel(); throw ActionError("WebDAV upload was cancelled") }
                if Date() >= deadline { task.cancel(); throw ActionError("WebDAV request timed out") }
            }
            if Task<Never, Never>.isCancelled { task.cancel(); throw ActionError("WebDAV upload was cancelled") }
            let (response, error) = result.get()
            if let error { throw ActionError("WebDAV connection failed (code \((error as NSError).code))") }
            guard let response else { throw ActionError("WebDAV server returned no HTTP response") }
            return response.statusCode
        }
        func exists(_ url: URL) throws -> Bool {
            let status = try request("PROPFIND", url: url, headers: ["Depth": "0"])
            if [200, 207].contains(status) { return true }
            if [404, 410].contains(status) { return false }
            throw ActionError("WebDAV could not check the destination (HTTP \(status))")
        }
        func requireSuccess(_ status: Int, operation: String) throws {
            guard (200...299).contains(status) else { throw ActionError("WebDAV \(operation) failed (HTTP \(status))") }
        }
        var prefix = ""
        for component in configuration.relativeFolders {
            prefix += (prefix.isEmpty ? "" : "/") + component
            let folder = try makeURL(prefix)
            if try !exists(folder) {
                let status = try request("MKCOL", url: folder)
                if !(200...299).contains(status) {
                    let existsAfterConflict = status == 405 ? try exists(folder) : false
                    if !existsAfterConflict { throw ActionError("WebDAV could not create the upload folder (HTTP \(status))") }
                }
            }
        }
        func destinationURL(_ name: String) throws -> URL {
            try makeURL((configuration.relativeFolders + [name]).joined(separator: "/"))
        }
        var targetName = name
        var target = try destinationURL(targetName)
        var replaceExistingFolder = false
        if try exists(target) {
            switch configuration.conflict {
            case .skip: return
            case .discard: throw ActionError("Invalid upload conflict policy")
            case .replace:
                replaceExistingFolder = type == .typeDirectory
            case .rename:
                let ext = rootURL.pathExtension
                let stem = ext.isEmpty || type == .typeDirectory ? name : rootURL.deletingPathExtension().lastPathComponent
                var found = false
                for index in 1...10_000 {
                    targetName = "\(stem) \(index)" + ((ext.isEmpty || type == .typeDirectory) ? "" : ".\(ext)")
                    target = try destinationURL(targetName)
                    if try !exists(target) { found = true; break }
                }
                guard found else { throw ActionError("Could not find an unused WebDAV destination name") }
            }
        }
        if type == .typeRegular {
            let headers = configuration.conflict == .replace ? [:] : ["If-None-Match": "*"]
            try localFiles.withSnapshot(nil) { snapshot in
                try requireSuccess(request("PUT", url: target, file: snapshot, headers: headers), operation: "upload")
            }
            return
        }
        let uploadName = replaceExistingFolder ? ".forel-upload-\(UUID().uuidString)" : targetName
        let uploadURL = try destinationURL(uploadName)
        try requireSuccess(request("MKCOL", url: uploadURL), operation: "create folder \(targetName)")
        do {
            for (_, relative, isDirectory) in entries {
                let destination = try destinationURL(uploadName + "/" + relative)
                if isDirectory { try requireSuccess(request("MKCOL", url: destination), operation: "create folder \(relative)") }
                else { try localFiles.withSnapshot(relative) { snapshot in
                    try requireSuccess(request("PUT", url: destination, file: snapshot, headers: ["If-None-Match": "*"]), operation: "upload")
                } }
            }
            if replaceExistingFolder {
                try requireSuccess(request("MOVE", url: uploadURL, headers: ["Destination": target.absoluteString, "Overwrite": "T"]), operation: "replace folder")
            }
        } catch {
            if replaceExistingFolder { _ = try? request("DELETE", url: uploadURL) }
            throw error
        }
    }
}
