import Foundation
import Testing
@testable import ForelCore

@Suite struct FTPUploadTests {
    @Test func localFTPReplaceAndFoldersWhenEnabled() throws {
        guard let python = ProcessInfo.processInfo.environment["FOREL_FTP_TEST_PYTHON"] else { return }
        let root = TempDir(), local = TempDir()
        try FileManager.default.createDirectory(atPath: (root.path as NSString).appendingPathComponent("incoming"), withIntermediateDirectories: true)
        let server = Process(); let output = Pipe()
        server.executableURL = URL(fileURLWithPath: python)
        server.arguments = ["-u", "-c", #"""
        import logging,sys
        from pyftpdlib.authorizers import DummyAuthorizer
        from pyftpdlib.handlers import FTPHandler
        from pyftpdlib.servers import FTPServer
        logging.disable(logging.CRITICAL)
        auth=DummyAuthorizer();auth.add_user('fixture','fixture-secret',sys.argv[1],perm='elradfmwMT')
        FTPHandler.authorizer=auth
        server=FTPServer(('127.0.0.1',0),FTPHandler)
        print(server.socket.getsockname()[1],flush=True)
        server.serve_forever()
        """#, root.path]
        server.standardOutput = output; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        var bytes = Data()
        while let next = try output.fileHandleForReading.read(upToCount: 1), !next.isEmpty, next.first != 10 { bytes.append(next) }
        let port = try #require(Int(String(decoding: bytes, as: UTF8.self)))
        func config(_ conflict: MoveConflictResolution) throws -> UploadConfiguration {
            try UploadConfiguration(action: makeAction(.upload, .object([
                "upload_protocol": .string("ftp"), "upload_host": .string("127.0.0.1"), "upload_port": .string(String(port)),
                "upload_username": .string("fixture"), "upload_remote_path": .string("/incoming"), ActionParam.onConflict: .string(conflict.rawValue)
            ])))
        }
        try FTPUpload.testConnection(configuration: config(.replace), password: "fixture-secret")
        #expect(throws: ActionError.self) { try FTPUpload.testConnection(configuration: config(.replace), password: "wrong") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: (root.path as NSString).appendingPathComponent("incoming")).isEmpty)
        let file = local.file("ftp # file.txt", contents: "uploaded")
        let remote = (root.path as NSString).appendingPathComponent("incoming/ftp # file.txt")
        try "old".write(toFile: remote, atomically: true, encoding: .utf8)
        #expect(throws: ActionError.self) { try FTPUpload.run(path: file, configuration: config(.skip), password: "fixture-secret") }
        #expect(throws: ActionError.self) { try FTPUpload.run(path: file, configuration: config(.rename), password: "fixture-secret") }
        #expect(try String(contentsOfFile: remote, encoding: .utf8) == "old")
        try FTPUpload.run(path: file, configuration: config(.replace), password: "fixture-secret")
        #expect(try String(contentsOfFile: remote, encoding: .utf8) == "uploaded")
        try FTPUpload.run(path: file, configuration: config(.replace).withRelativeFolders(["level1", "level2"]), password: "fixture-secret")
        #expect(try String(contentsOfFile: (root.path as NSString).appendingPathComponent("incoming/level1/level2/ftp # file.txt"), encoding: .utf8) == "uploaded")
        let folder = local.dir("folder")
        try FileManager.default.createDirectory(atPath: (folder as NSString).appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "child".write(toFile: (folder as NSString).appendingPathComponent("nested/file.txt"), atomically: true, encoding: .utf8)
        try FTPUpload.run(path: folder, configuration: config(.replace), password: "fixture-secret")
        try FTPUpload.run(path: folder, configuration: config(.replace).withRelativeFolders(["new", "folders"]), password: "fixture-secret")
        #expect(FileManager.default.fileExists(atPath: (root.path as NSString).appendingPathComponent("incoming/new/folders/folder/nested/file.txt")))
        #expect(try String(contentsOfFile: (root.path as NSString).appendingPathComponent("incoming/folder/nested/file.txt"), encoding: .utf8) == "child")
        #expect(throws: ActionError.self) { try FTPUpload.run(path: folder, configuration: config(.replace), password: "fixture-secret") }
        #expect(try String(contentsOfFile: (root.path as NSString).appendingPathComponent("incoming/folder/nested/file.txt"), encoding: .utf8) == "child")
    }

    @Test func localFTPSVerifiesCertificatesWhenEnabled() throws {
        guard let python = ProcessInfo.processInfo.environment["FOREL_FTP_TEST_PYTHON"] else { return }
        let root = TempDir(), local = TempDir()
        try FileManager.default.createDirectory(atPath: (root.path as NSString).appendingPathComponent("incoming"), withIntermediateDirectories: true)
        let key = (local.path as NSString).appendingPathComponent("key.pem")
        let cert = (local.path as NSString).appendingPathComponent("cert.pem")
        let conf = local.file("openssl.cnf", contents: "[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=localhost\n[v3]\nbasicConstraints=CA:TRUE\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n")
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        generator.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-config", conf]
        generator.standardOutput = FileHandle.nullDevice; generator.standardError = FileHandle.nullDevice
        try generator.run(); generator.waitUntilExit()
        #expect(generator.terminationStatus == 0)
        for mode in [UploadProtocol.ftpsExplicit, .ftpsImplicit] {
            let server = Process(), output = Pipe()
            server.executableURL = URL(fileURLWithPath: python)
            server.arguments = ["-u", "-c", #"""
            import logging,sys
            from pyftpdlib.authorizers import DummyAuthorizer
            from pyftpdlib.handlers import TLS_FTPHandler
            from pyftpdlib.servers import FTPServer
            logging.disable(logging.CRITICAL)
            auth=DummyAuthorizer();auth.add_user('fixture','fixture-secret',sys.argv[1],perm='elradfmwMT')
            class Handler(TLS_FTPHandler):
              def handle(self):
                if sys.argv[4]=='implicit': self.secure_connection(self.ssl_context)
                super().handle()
            Handler.authorizer=auth;Handler.certfile=sys.argv[2];Handler.keyfile=sys.argv[3]
            Handler.tls_control_required=True;Handler.tls_data_required=True
            server=FTPServer(('127.0.0.1',0),Handler);print(server.socket.getsockname()[1],flush=True);server.serve_forever()
            """#, root.path, cert, key, mode == .ftpsImplicit ? "implicit" : "explicit"]
            server.standardOutput = output; server.standardError = FileHandle.nullDevice
            try server.run()
            defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
            var bytes = Data()
            while let next = try output.fileHandleForReading.read(upToCount: 1), !next.isEmpty, next.first != 10 { bytes.append(next) }
            let port = try #require(Int(String(decoding: bytes, as: UTF8.self)))
            let config = try UploadConfiguration(action: makeAction(.upload, .object([
                "upload_protocol": .string(mode.rawValue), "upload_host": .string("127.0.0.1"), "upload_port": .string(String(port)),
                "upload_username": .string("fixture"), "upload_remote_path": .string("/incoming"), ActionParam.onConflict: .string("replace")
            ])))
            let file = local.file("\(mode.rawValue).txt", contents: "secure")
            #expect(throws: ActionError.self) { try FTPUpload.testConnection(configuration: config, password: "fixture-secret") }
            try FTPUpload.testConnection(configuration: config, password: "fixture-secret", testCAPath: cert)
            #expect(throws: ActionError.self) { try FTPUpload.run(path: file, configuration: config, password: "fixture-secret") }
            try FTPUpload.run(path: file, configuration: config, password: "fixture-secret", testCAPath: cert)
            #expect(try String(contentsOfFile: (root.path as NSString).appendingPathComponent("incoming/\(mode.rawValue).txt"), encoding: .utf8) == "secure")
        }
    }
}
