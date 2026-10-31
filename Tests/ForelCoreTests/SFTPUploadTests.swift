import Foundation
import Testing
@testable import ForelCore

@Suite struct SFTPUploadTests {
    @Test func connectionTestChecksDirectoryWithoutWriting() throws {
        let root = TempDir(), local = TempDir()
        try FileManager.default.createDirectory(atPath: (root.path as NSString).appendingPathComponent("incoming"), withIntermediateDirectories: true)
        let server = try makeServer(in: local)
        let env = ["FOREL_SFTP_TEST_ROOT": root.path]
        try SFTPUpload.testConnection(configuration: configuration(.replace), password: "private secret", sshExecutable: URL(fileURLWithPath: server), testEnvironment: env)
        #expect(throws: ActionError.self) { try SFTPUpload.testConnection(configuration: configuration(.replace), password: "wrong", sshExecutable: URL(fileURLWithPath: server), testEnvironment: env) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: (root.path as NSString).appendingPathComponent("incoming")).isEmpty)
    }
    private func configuration(_ conflict: MoveConflictResolution) throws -> UploadConfiguration {
        try UploadConfiguration(action: makeAction(.upload, .object([
            "upload_protocol": .string("sftp"), "upload_host": .string("localhost"),
            "upload_username": .string("fixture"), "upload_remote_path": .string("/incoming"),
            ActionParam.onConflict: .string(conflict.rawValue)
        ])))
    }

    @Test func sftpUsesExclusiveStagingAndPreservesExistingDestinations() throws {
        let root = TempDir(), local = TempDir()
        try FileManager.default.createDirectory(atPath: (root.path as NSString).appendingPathComponent("incoming"), withIntermediateDirectories: true)
        let server = try makeServer(in: local)
        let file = local.file("space ' name.txt", contents: "new")
        let target = (root.path as NSString).appendingPathComponent("incoming/space ' name.txt")
        try "old".write(toFile: target, atomically: true, encoding: .utf8)
        func upload(_ conflict: MoveConflictResolution) throws {
            try SFTPUpload.run(path: file, configuration: configuration(conflict), password: "private secret",
                               sshExecutable: URL(fileURLWithPath: server), testEnvironment: ["FOREL_SFTP_TEST_ROOT": root.path])
        }
        try upload(.skip)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "old")
        try upload(.rename)
        #expect(try String(contentsOfFile: (root.path as NSString).appendingPathComponent("incoming/space ' name 1.txt"), encoding: .utf8) == "new")
        try upload(.replace)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "new")
        try SFTPUpload.run(path: file, configuration: configuration(.replace).withRelativeFolders(["level1", "level2"]), password: "private secret", sshExecutable: URL(fileURLWithPath: server), testEnvironment: ["FOREL_SFTP_TEST_ROOT": root.path])
        #expect(try String(contentsOfFile: (root.path as NSString).appendingPathComponent("incoming/level1/level2/space ' name.txt"), encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: (root.path as NSString).appendingPathComponent("incoming")).allSatisfy { !$0.hasPrefix(".forel-upload-") })
    }

    @Test func sftpUploadsFoldersWithoutFollowingSymlinks() throws {
        let root = TempDir(), local = TempDir()
        try FileManager.default.createDirectory(atPath: (root.path as NSString).appendingPathComponent("incoming"), withIntermediateDirectories: true)
        let server = try makeServer(in: local)
        let folder = local.dir("folder")
        try FileManager.default.createDirectory(atPath: (folder as NSString).appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "child".write(toFile: (folder as NSString).appendingPathComponent("nested/child.txt"), atomically: true, encoding: .utf8)
        try SFTPUpload.run(path: folder, configuration: configuration(.rename), password: "private secret", sshExecutable: URL(fileURLWithPath: server), testEnvironment: ["FOREL_SFTP_TEST_ROOT": root.path])
        #expect(try String(contentsOfFile: (root.path as NSString).appendingPathComponent("incoming/folder/nested/child.txt"), encoding: .utf8) == "child")
        try FileManager.default.createSymbolicLink(atPath: (folder as NSString).appendingPathComponent("link"), withDestinationPath: "/tmp")
        #expect(throws: ActionError.self) {
            try SFTPUpload.run(path: folder, configuration: configuration(.rename), password: "private secret", sshExecutable: URL(fileURLWithPath: server), testEnvironment: ["FOREL_SFTP_TEST_ROOT": root.path])
        }
    }

    @Test func standardV3FallbackCreatesFinalFileExclusively() throws {
        let root = TempDir(), local = TempDir()
        try FileManager.default.createDirectory(atPath: (root.path as NSString).appendingPathComponent("incoming"), withIntermediateDirectories: true)
        let server = try makeServer(in: local)
        let file = local.file("fallback.txt", contents: "new")
        let original = (root.path as NSString).appendingPathComponent("incoming/fallback.txt")
        try "old".write(toFile: original, atomically: true, encoding: .utf8)
        let env = ["FOREL_SFTP_TEST_ROOT": root.path, "FOREL_SFTP_NO_HARDLINK": "1"]
        try SFTPUpload.run(path: file, configuration: configuration(.rename), password: "private secret", sshExecutable: URL(fileURLWithPath: server), testEnvironment: env)
        #expect(try String(contentsOfFile: original, encoding: .utf8) == "old")
        #expect(try String(contentsOfFile: (root.path as NSString).appendingPathComponent("incoming/fallback 1.txt"), encoding: .utf8) == "new")
        var failureEnv = env; failureEnv["FOREL_SFTP_FAIL_WRITE"] = "1"
        #expect(throws: ActionError.self) {
            try SFTPUpload.run(path: file, configuration: configuration(.rename), password: "private secret", sshExecutable: URL(fileURLWithPath: server), testEnvironment: failureEnv)
        }
        #expect(FileManager.default.fileExists(atPath: (root.path as NSString).appendingPathComponent("incoming/fallback 2.txt")))
        #expect(try String(contentsOfFile: original, encoding: .utf8) == "old")
    }

    @Test func realLocalSSHUsesTrustedHostAndKeyWhenEnabled() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_SFTP_REAL_ROOT"],
              let port = ProcessInfo.processInfo.environment["FOREL_SFTP_REAL_PORT"] else { return }
        let dir = TempDir()
        let file = dir.file("real input.txt", contents: "sftp fixture")
        let remote = (root as NSString).appendingPathComponent("remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: remote) }
        let action = makeAction(.upload, .object([
            "upload_protocol": .string("sftp"), "upload_host": .string("127.0.0.1"),
            "upload_port": .string(port), "upload_username": .string(NSUserName()),
            "upload_identity_path": .string((root as NSString).appendingPathComponent("client")),
            "upload_remote_path": .string(remote), ActionParam.onConflict: .string("rename")
        ]))
        let config = try UploadConfiguration(action: action)
        let trusted = (root as NSString).appendingPathComponent("known_hosts")
        try SFTPUpload.testConnection(configuration: config, password: nil, knownHostsPath: trusted)
        try SFTPUpload.run(path: file, configuration: config, password: nil, knownHostsPath: trusted)
        #expect(try String(contentsOfFile: (remote as NSString).appendingPathComponent("real input.txt"), encoding: .utf8) == "sftp fixture")
        let untrusted = dir.file("empty-known-hosts")
        #expect(throws: ActionError.self) { try SFTPUpload.testConnection(configuration: config, password: nil, knownHostsPath: untrusted) }
        #expect(throws: ActionError.self) { try SFTPUpload.run(path: file, configuration: config, password: nil, knownHostsPath: untrusted) }
        let encrypted = (root as NSString).appendingPathComponent("client-encrypted")
        if FileManager.default.fileExists(atPath: encrypted) {
            var encryptedAction = action
            if case .object(var params) = encryptedAction.params {
                params["upload_identity_path"] = .string(encrypted)
                encryptedAction.params = .object(params)
            }
            try SFTPUpload.run(path: file, configuration: UploadConfiguration(action: encryptedAction), password: "fixture-secret", knownHostsPath: trusted)
            #expect(try String(contentsOfFile: (remote as NSString).appendingPathComponent("real input 1.txt"), encoding: .utf8) == "sftp fixture")
        }
    }

    @Test func cancellationStopsWaitingForSFTPServer() async throws {
        let dir = TempDir()
        let file = dir.file("input.txt")
        let server = dir.file("sleeping-ssh", contents: "#!/bin/sh\nexec /bin/sleep 30\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server)
        let config = try configuration(.rename)
        let task = Task.detached {
            try SFTPUpload.run(path: file, configuration: config, password: nil, sshExecutable: URL(fileURLWithPath: server))
        }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        do { try await task.value; Issue.record("Cancelled SFTP upload unexpectedly succeeded") }
        catch { #expect(String(describing: error).contains("cancelled")) }
    }

    @Test func cancellationStopsWhenServerDoesNotReadRequests() async throws {
        let dir = TempDir()
        let file = dir.file("input.txt")
        let server = dir.file("blocked-ssh", contents: "#!/usr/bin/python3\nimport sys,struct,time\nsys.stdin.buffer.read(9)\nsys.stdout.buffer.write(struct.pack('>IBI',5,2,3));sys.stdout.buffer.flush()\ntime.sleep(30)\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server)
        let action = makeAction(.upload, .object([
            "upload_protocol": .string("sftp"), "upload_host": .string("127.0.0.1"),
            "upload_username": .string("fixture"), "upload_remote_path": .string("/" + String(repeating: "a", count: 60_000)),
            ActionParam.onConflict: .string("replace")
        ]))
        let config = try UploadConfiguration(action: action)
        let task = Task.detached { try SFTPUpload.run(path: file, configuration: config, password: nil, sshExecutable: URL(fileURLWithPath: server)) }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        do { try await task.value; Issue.record("Cancelled blocked send unexpectedly succeeded") }
        catch { #expect(String(describing: error).contains("cancelled")) }
    }

    @Test func realPasswordAuthenticationWhenEnabled() throws {
        guard let python = ProcessInfo.processInfo.environment["FOREL_SFTP_PARAMIKO_PYTHON"],
              let keyRoot = ProcessInfo.processInfo.environment["FOREL_SFTP_REAL_ROOT"] else { return }
        let root = TempDir(), local = TempDir()
        try FileManager.default.createDirectory(atPath: (root.path as NSString).appendingPathComponent("incoming"), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", "-c", passwordServer, root.path, (keyRoot as NSString).appendingPathComponent("host")]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        var bytes = Data()
        while let next = try output.fileHandleForReading.read(upToCount: 1), !next.isEmpty, next.first != 10 { bytes.append(next) }
        let port = try #require(Int(String(decoding: bytes, as: UTF8.self)))
        let key = try String(contentsOfFile: (keyRoot as NSString).appendingPathComponent("host.pub"), encoding: .utf8)
        let knownHosts = local.file("known_hosts", contents: "[127.0.0.1]:\(port) \(key)")
        let action = makeAction(.upload, .object([
            "upload_protocol": .string("sftp"), "upload_host": .string("127.0.0.1"), "upload_port": .string(String(port)),
            "upload_username": .string("fixture"), "upload_remote_path": .string("/incoming"), ActionParam.onConflict: .string("replace")
        ]))
        let config = try UploadConfiguration(action: action)
        let file = local.file("password input.txt", contents: "authenticated")
        try SFTPUpload.run(path: file, configuration: config, password: "fixture-secret", knownHostsPath: knownHosts)
        #expect(try String(contentsOfFile: (root.path as NSString).appendingPathComponent("incoming/password input.txt"), encoding: .utf8) == "authenticated")
        #expect(throws: ActionError.self) { try SFTPUpload.run(path: file, configuration: config, password: "wrong", knownHostsPath: knownHosts) }
    }

    private var passwordServer: String { #"""
    import os, socket, sys, threading, time, paramiko
    root=sys.argv[1]; hostkey=paramiko.Ed25519Key.from_private_key_file(sys.argv[2])
    class Auth(paramiko.ServerInterface):
      def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if (username,password)==('fixture','fixture-secret') else paramiko.AUTH_FAILED
      def get_allowed_auths(self, username): return 'password'
      def check_channel_request(self, kind, chanid): return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    class SFTP(paramiko.SFTPServerInterface):
      def path(self,p):
        p=os.path.normpath(os.path.join(root,p.lstrip('/')))
        if not p.startswith(root+'/'): raise OSError(13,'invalid')
        return p
      def lstat(self,p):
        try: return paramiko.SFTPAttributes.from_stat(os.lstat(self.path(p)))
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
      stat=lstat
      def open(self,p,flags,attr):
        try:
          fd=os.open(self.path(p),flags,0o600); f=os.fdopen(fd,'r+b' if flags & os.O_RDWR else 'wb' if flags & os.O_WRONLY else 'rb')
          h=paramiko.SFTPHandle(flags);h.readfile=f;h.writefile=f;return h
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
      def remove(self,p):
        try: os.unlink(self.path(p));return paramiko.SFTP_OK
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
      def rename(self,a,b):
        try:
          src,dst=self.path(a),self.path(b)
          if os.path.lexists(dst): return paramiko.SFTP_FAILURE
          os.rename(src,dst);return paramiko.SFTP_OK
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
      def posix_rename(self,a,b):
        try: os.replace(self.path(a),self.path(b));return paramiko.SFTP_OK
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
      def mkdir(self,p,attr):
        try: os.mkdir(self.path(p));return paramiko.SFTP_OK
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
      def rmdir(self,p):
        try: os.rmdir(self.path(p));return paramiko.SFTP_OK
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    def serve(c):
      t=paramiko.Transport(c);t.add_server_key(hostkey);t.set_subsystem_handler('sftp',paramiko.SFTPServer,SFTP)
      try:
        t.start_server(server=Auth())
        while t.is_active(): time.sleep(.05)
      except Exception: pass
      finally: t.close()
    s=socket.socket();s.bind(('127.0.0.1',0));s.listen(5);print(s.getsockname()[1],flush=True)
    while True:
      c,_=s.accept();threading.Thread(target=serve,args=(c,),daemon=True).start()
    """# }

    private func makeServer(in dir: TempDir) throws -> String {
        let source = #"""
        #!/usr/bin/python3
        import os, struct, sys, subprocess
        root=os.environ['FOREL_SFTP_TEST_ROOT']
        config=open(sys.argv[2]).read()
        if 'StrictHostKeyChecking yes' not in config or 'private secret' in config or 'private secret' in ' '.join(sys.argv): sys.exit(4)
        if subprocess.check_output([os.environ['SSH_ASKPASS']]).decode() != 'private secret': sys.exit(5)
        def read(n):
          b=b''
          while len(b)<n:
            x=sys.stdin.buffer.read(n-len(b))
            if not x: sys.exit(0)
            b+=x
          return b
        def u32(n): return struct.pack('>I',n)
        def string(b): return u32(len(b))+b
        def send(b): sys.stdout.buffer.write(u32(len(b))+b);sys.stdout.buffer.flush()
        def parse(b,at):
          n=struct.unpack('>I',b[at:at+4])[0];at+=4
          return b[at:at+n],at+n
        def loc(p):
          p=p.decode('utf8'); path=os.path.normpath(os.path.join(root,p.lstrip('/')))
          if not path.startswith(root+'/'): raise ValueError('bad path')
          return path
        def status(i,code): send(bytes([101])+u32(i)+u32(code)+string(b'')+string(b''))
        handles={}; seq=0
        while True:
          n=struct.unpack('>I',read(4))[0]; b=read(n); op=b[0]
          if op==1:
            ext=string(b'posix-rename@openssh.com')+string(b'1')
            if 'FOREL_SFTP_NO_HARDLINK' not in os.environ: ext+=string(b'hardlink@openssh.com')+string(b'1')
            send(bytes([2])+u32(3)+ext);continue
          i=struct.unpack('>I',b[1:5])[0]; at=5
          try:
            if op==3:
              name,at=parse(b,at);p=loc(name);flags=struct.unpack('>I',b[at:at+4])[0]
              if flags != 42: status(i,4);continue
              f=open(p,'xb');seq+=1;h=str(seq).encode();handles[h]=f
              send(bytes([102])+u32(i)+string(h))
            elif op==6:
              h,at=parse(b,at);offset=struct.unpack('>Q',b[at:at+8])[0];at+=8;chunk,at=parse(b,at)
              if 'FOREL_SFTP_FAIL_WRITE' in os.environ: status(i,4)
              else: handles[h].seek(offset);handles[h].write(chunk);status(i,0)
            elif op==11:
              name,at=parse(b,at); p=loc(name)
              if not os.path.isdir(p): status(i,2);continue
              seq+=1;h=str(seq).encode();handles[h]=os.scandir(p)
              send(bytes([102])+u32(i)+string(h))
            elif op==4:
              h,at=parse(b,at);handles.pop(h).close();status(i,0)
            elif op==7:
              name,at=parse(b,at)
              if os.path.lexists(loc(name)): send(bytes([105])+u32(i)+u32(0))
              else: status(i,2)
            elif op==14:
              name,at=parse(b,at);os.mkdir(loc(name));status(i,0)
            elif op in (13,15):
              name,at=parse(b,at); (os.rmdir if op==15 else os.unlink)(loc(name));status(i,0)
            elif op==18:
              x,at=parse(b,at);y,at=parse(b,at);x=loc(x);y=loc(y)
              if os.path.lexists(y): status(i,4)
              else: os.rename(x,y);status(i,0)
            elif op==200:
              ext,at=parse(b,at);x,at=parse(b,at);y,at=parse(b,at)
              if ext==b'posix-rename@openssh.com': os.replace(loc(x),loc(y));status(i,0)
              elif ext==b'hardlink@openssh.com': os.link(loc(x),loc(y));status(i,0)
              else: status(i,8)
            else: status(i,8)
          except FileNotFoundError: status(i,2)
          except (OSError,ValueError,KeyError): status(i,4)
        """#
        let path = dir.file("fake-ssh", contents: source + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }
}
