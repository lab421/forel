import Foundation
import Testing
@testable import ForelCore

@Suite struct WebDAVUploadTests {
    @Test func localUploadRejectsSymlinkSwapsAndSnapshotsBytes() throws {
        let dir = TempDir()
        let nested = dir.dir("nested")
        let source = (nested as NSString).appendingPathComponent("file.txt")
        try "original".write(toFile: source, atomically: true, encoding: .utf8)
        let local = try UploadLocalFiles(path: dir.path, directory: true)
        try local.withSnapshot("nested/file.txt") { snapshot in
            try "changed".write(toFile: source, atomically: true, encoding: .utf8)
            #expect(try String(contentsOf: snapshot, encoding: .utf8) == "original")
        }
        try FileManager.default.removeItem(atPath: source)
        try FileManager.default.createSymbolicLink(atPath: source, withDestinationPath: "/etc/passwd")
        #expect(throws: ActionError.self) { try local.withSnapshot("nested/file.txt") { _ in } }
        try FileManager.default.removeItem(atPath: nested)
        try FileManager.default.createSymbolicLink(atPath: nested, withDestinationPath: "/etc")
        #expect(throws: ActionError.self) { try local.withSnapshot("nested/passwd") { _ in } }
    }
    private func configuration(port: Int, remote: String = "/incoming", conflict: MoveConflictResolution) throws -> UploadConfiguration {
        let action = makeAction(.upload, .object([
            "upload_protocol": .string("webdav"), "upload_host": .string("127.0.0.1"),
            "upload_port": .string(String(port)), "upload_username": .string("user"),
            "upload_remote_path": .string(remote), ActionParam.onConflict: .string(conflict.rawValue)
        ]))
        return try UploadConfiguration(action: action)
    }

    @Test func webdavUploadsFilesFoldersAndRespectsConflicts() throws {
        let remote = TempDir()
        let source = TempDir()
        try FileManager.default.createDirectory(atPath: (remote.path as NSString).appendingPathComponent("incoming"), withIntermediateDirectories: true)
        let (server, port) = try startServer(root: remote.path)
        defer { server.terminate(); server.waitUntilExit() }
        let file = source.file("report #1.txt", contents: "new contents")
        let old = (remote.path as NSString).appendingPathComponent("incoming/report #1.txt")
        try "old".write(toFile: old, atomically: true, encoding: .utf8)
        try WebDAVUpload.run(path: file, configuration: configuration(port: port, conflict: .skip), password: "secret")
        #expect(try String(contentsOfFile: old, encoding: .utf8) == "old")
        try WebDAVUpload.run(path: file, configuration: configuration(port: port, conflict: .rename), password: "secret")
        #expect(try String(contentsOfFile: (remote.path as NSString).appendingPathComponent("incoming/report #1 1.txt"), encoding: .utf8) == "new contents")
        try WebDAVUpload.run(path: file, configuration: configuration(port: port, conflict: .replace), password: "secret")
        #expect(try String(contentsOfFile: old, encoding: .utf8) == "new contents")
        try WebDAVUpload.run(path: file, configuration: configuration(port: port, conflict: .replace).withRelativeFolders(["level1", "level2"]), password: "secret")
        #expect(try String(contentsOfFile: (remote.path as NSString).appendingPathComponent("incoming/level1/level2/report #1.txt"), encoding: .utf8) == "new contents")
        let folder = source.dir("folder")
        try FileManager.default.createDirectory(atPath: (folder as NSString).appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "nested".write(toFile: (folder as NSString).appendingPathComponent("nested/file.txt"), atomically: true, encoding: .utf8)
        try WebDAVUpload.run(path: folder, configuration: configuration(port: port, conflict: .rename), password: "secret")
        #expect(try String(contentsOfFile: (remote.path as NSString).appendingPathComponent("incoming/folder/nested/file.txt"), encoding: .utf8) == "nested")
        try "original".write(toFile: (remote.path as NSString).appendingPathComponent("incoming/folder/old.txt"), atomically: true, encoding: .utf8)
        let marker = (remote.path as NSString).appendingPathComponent("fail-upload")
        try "".write(toFile: marker, atomically: true, encoding: .utf8)
        #expect(throws: ActionError.self) { try WebDAVUpload.run(path: folder, configuration: configuration(port: port, conflict: .replace), password: "secret") }
        #expect(try String(contentsOfFile: (remote.path as NSString).appendingPathComponent("incoming/folder/old.txt"), encoding: .utf8) == "original")
        try FileManager.default.removeItem(atPath: marker)
        try WebDAVUpload.run(path: folder, configuration: configuration(port: port, conflict: .replace), password: "secret")
        #expect(!FileManager.default.fileExists(atPath: (remote.path as NSString).appendingPathComponent("incoming/folder/old.txt")))
        #expect(try String(contentsOfFile: (remote.path as NSString).appendingPathComponent("incoming/folder/nested/file.txt"), encoding: .utf8) == "nested")
    }

    @Test func redirectsAreNotFollowedAndCredentialsAreNotForwarded() throws {
        let remote = TempDir()
        let source = TempDir()
        let (server, port) = try startServer(root: remote.path)
        defer { server.terminate(); server.waitUntilExit() }
        let file = source.file("file.txt")
        #expect(throws: ActionError.self) {
            try WebDAVUpload.run(path: file, configuration: configuration(port: port, remote: "/redirect", conflict: .rename), password: "secret")
        }
        #expect(!FileManager.default.fileExists(atPath: (remote.path as NSString).appendingPathComponent("redirect-followed")))
    }

    @Test func cancellingTaskStopsPendingRequest() async throws {
        let remote = TempDir()
        let source = TempDir()
        let (server, port) = try startServer(root: remote.path)
        defer { server.terminate(); server.waitUntilExit() }
        let file = source.file("file.txt")
        let config = try configuration(port: port, remote: "/slow", conflict: .rename)
        let task = Task.detached { try WebDAVUpload.run(path: file, configuration: config, password: "secret") }
        defer { task.cancel() }
        let started = (remote.path as NSString).appendingPathComponent("slow-request-started")
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: started), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard FileManager.default.fileExists(atPath: started) else {
            throw ActionError("The pending WebDAV request did not start")
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancelled upload unexpectedly succeeded")
        } catch {
            #expect(String(describing: error).contains("cancelled"))
        }
        #expect(!FileManager.default.fileExists(atPath: (remote.path as NSString).appendingPathComponent("slow-upload-attempted")))
    }

    private func startServer(root: String) throws -> (Process, Int) {
        let source = #"""
        import base64, http.server, os, shutil, sys, time, urllib.parse
        root=sys.argv[1]
        class Handler(http.server.BaseHTTPRequestHandler):
          def log_message(self,*args): pass
          def location(self):
            path=urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
            return os.path.join(root,path.lstrip('/'))
          def auth(self):
            if self.path.startswith('/stolen'):
              open(os.path.join(root,'redirect-followed'),'w').close()
            if self.headers.get('Authorization') != 'Basic '+base64.b64encode(b'user:secret').decode():
              self.send_response(401); self.end_headers(); return False
            return True
          def do_PROPFIND(self):
            if not self.auth(): return
            if self.path.startswith('/slow/'):
              open(os.path.join(root,'slow-request-started'),'w').close()
              time.sleep(60)
            if self.path.startswith('/redirect/'):
              self.send_response(302); self.send_header('Location','/stolen'); self.end_headers(); return
            self.send_response(207 if os.path.exists(self.location()) else 404); self.end_headers()
          def do_MKCOL(self):
            if not self.auth(): return
            try: os.mkdir(self.location()); code=201
            except FileExistsError: code=405
            except FileNotFoundError: code=409
            self.send_response(code); self.end_headers()
          def do_PUT(self):
            if not self.auth(): return
            if self.path.startswith('/slow/'):
              open(os.path.join(root,'slow-upload-attempted'),'w').close()
            if os.path.exists(os.path.join(root,'fail-upload')):
              self.send_response(500); self.end_headers(); return
            loc=self.location()
            if self.headers.get('If-None-Match') == '*' and os.path.exists(loc):
              self.send_response(412); self.end_headers(); return
            try:
              with open(loc,'wb') as f: f.write(self.rfile.read(int(self.headers.get('Content-Length','0'))))
              code=201
            except FileNotFoundError: code=409
            self.send_response(code); self.end_headers()
          def do_MOVE(self):
            if not self.auth(): return
            destination=urllib.parse.unquote(urllib.parse.urlsplit(self.headers['Destination']).path)
            dest=os.path.join(root,destination.lstrip('/'))
            if os.path.exists(dest):
              if self.headers.get('Overwrite') != 'T': self.send_response(412); self.end_headers(); return
              if os.path.isdir(dest): shutil.rmtree(dest)
              else: os.unlink(dest)
            os.rename(self.location(),dest)
            self.send_response(204); self.end_headers()
          def do_DELETE(self):
            if not self.auth(): return
            loc=self.location()
            if os.path.isdir(loc): shutil.rmtree(loc)
            else: os.unlink(loc)
            self.send_response(204); self.end_headers()
        s=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        print(s.server_port,flush=True)
        s.serve_forever()
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", source, root]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var bytes = Data()
        while let next = try output.fileHandleForReading.read(upToCount: 1), !next.isEmpty, next.first != 10 { bytes.append(next) }
        guard let port = Int(String(decoding: bytes, as: UTF8.self)), port > 0 else { process.terminate(); throw ActionError("Could not start local test server") }
        return (process, port)
    }
}
