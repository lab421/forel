import Foundation
import Testing
@testable import ForelCore

@Suite struct UploadConfigurationTests {
    @Test func serverCatalogAndInlineMigrationKeepRulesReferential() throws {
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: "/tmp/upload-catalog-test")
        try db.insertFolder(folder)
        let action = makeAction(.upload, .object(["upload_protocol": .string("sftp"), "upload_host": .string("example.com"), "upload_username": .string("alice"), "upload_credential_id": .string("legacy-key"), "upload_remote_path": .string("/incoming")]))
        var rule = makeRule(folderId: folder.id, name: "Upload", actions: [action])
        rule.actions[0].ruleId = rule.id
        try db.insertRule(rule)
        let server = try #require(db.loadUploadServers().first)
        #expect(server.credentialID == "legacy-key")
        let saved = try #require(db.listRules(folderId: folder.id).first)
        let savedAction = try #require(saved.actions.first)
        #expect(savedAction.params["upload_server_id"]?.stringValue == server.id)
        #expect(savedAction.params["upload_host"] == nil)
        #expect(try UploadConfiguration(action: savedAction, serverLookup: { _ in server }).host == "example.com")
        try db.deleteUploadServer(id: server.id)
        #expect(try db.listRules(folderId: folder.id).count == 1)
        #expect(throws: ActionError.self) { try UploadConfiguration(action: savedAction, serverLookup: { _ in nil }) }
    }

    @Test func nativeTransferNeverCarriesOrRebindsServerDetails() throws {
        let action = makeAction(.upload, .object(["upload_server_id": .string("server-id"), "upload_host": .string("private.example"), "upload_credential_id": .string("credential-id"), "upload_url": .string("ftp://alice:secret@example.com"), "upload_remote_path": .string("/incoming")]))
        let data = try RuleTransfer.exportForel([makeRule(name: "Upload", actions: [action])])
        let json = String(decoding: data, as: UTF8.self)
        for sensitive in ["server-id", "private.example", "credential-id", "secret", "upload_url"] { #expect(!json.contains(sensitive)) }
        let imported = try RuleTransfer.importRules(from: data, folderId: "destination")
        #expect(imported.rules.first?.enabled == false)
        #expect(imported.rules.first?.actions.first?.params["upload_server_id"] == nil)
        #expect(imported.rules.first?.actions.first?.params["upload_remote_path"]?.stringValue == "/incoming")
    }

    @Test func legacyUploadURLIsRemovedWithoutBindingDestination() throws {
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: "/tmp/legacy-url-test")
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Legacy", actions: [makeAction(.upload, .object(["upload_url": .string("ftp://user:secret@example.com/private")]))])
        rule.actions[0].ruleId = rule.id
        try db.insertRule(rule)
        let saved = try #require(db.listRules(folderId: folder.id).first?.actions.first)
        #expect(saved.params["upload_url"] == nil)
        #expect(saved.params["upload_server_id"] == nil)
        #expect(try db.loadUploadServers().isEmpty)
        #expect(throws: ActionError.self) { try UploadConfiguration(action: saved, serverLookup: { _ in nil }) }
    }

    @Test func openingExistingDatabaseMigratesInlineUpload() throws {
        let dir = TempDir()
        let path = (dir.path as NSString).appendingPathComponent("rules.db")
        let folder = WatchedFolder(path: dir.path)
        let action = makeAction(.upload, .object([:]))
        var rule = makeRule(folderId: folder.id, name: "Old upload", actions: [action])
        rule.actions[0].ruleId = rule.id
        do {
            let db = try Database(path: path)
            try db.insertFolder(folder); try db.insertRule(rule)
            let update = try db.statement("UPDATE actions SET params=?1 WHERE id=?2")
            update.bind(1, JSONValue.object(["upload_protocol": .string("ftp"), "upload_host": .string("legacy.example"), "upload_username": .string("alice"), "upload_remote_path": .string("/old")]).jsonString)
            update.bind(2, action.id)
            try update.runToCompletion()
        }
        let reopened = try Database(path: path)
        let server = try #require(reopened.loadUploadServers().first)
        let saved = try #require(reopened.listRules(folderId: folder.id).first?.actions.first)
        #expect(saved.params["upload_server_id"]?.stringValue == server.id)
        #expect(saved.params["upload_host"] == nil)
        #expect(server.credentialID == action.id)
    }
    private final class Platform: ActionPlatform, @unchecked Sendable {
        var uploads: [UploadConfiguration] = []
        func upload(path: String, configuration: UploadConfiguration) throws { uploads.append(configuration) }
        func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws {}
        func showInFinder(path: String, bringToFront: Bool) throws {}
        func notify(text: String, sound: Bool) throws {}
        func pause(seconds: TimeInterval) throws {}
        func trash(path: String) throws -> String { throw ActionError("Unexpected trash") }
    }

    @Test func savedServerResolvesAndMissingServerFailsAcrossExecutionPaths() throws {
        let dir = TempDir()
        let folder = WatchedFolder(path: dir.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let server = UploadServer(name: "Example", protocolType: .webdavs, host: "example.com", username: "user")
        try db.saveUploadServer(server)
        var rule = makeRule(folderId: folder.id, name: "Upload", actions: [makeAction(.upload, .object(["upload_server_id": .string(server.id), "upload_remote_path": .string("/incoming")]))])
        rule.actions[0].ruleId = rule.id
        try db.insertRule(rule)
        let platform = Platform()
        func file(_ name: String) throws -> String {
            let path = (dir.path as NSString).appendingPathComponent(name)
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }
        let preview = try file("preview.txt")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule], uploadServers: [server])?.rules.first?.actions.first?.status == .wouldRun)
        let manual = try file("manual.txt")
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "manual", platform: platform, uploadServers: [server]).history.first?.status == .applied)
        WatcherCoordinator(db: db, actionPlatform: platform).handle(path: try file("watched.txt"))
        #expect(try db.listHistory().first?.status == .applied)
        #expect(platform.uploads.count == 2)
        try db.deleteUploadServer(id: server.id)
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule], uploadServers: [])?.rules.first?.actions.first?.status == .blocked)
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "missing", platform: platform, uploadServers: []).history.first?.status == .failed)
        WatcherCoordinator(db: db, actionPlatform: platform).handle(path: try file("missing-watched.txt"))
        #expect(try db.listHistory().contains { $0.status == .failed && ($0.message?.contains("server") == true) })
        #expect(platform.uploads.count == 2)
    }

    @Test func uploadFolderStructureUsesSourceHierarchyInPreviewManualAndWatcher() throws {
        let source = TempDir()
        let nested = (source.path as NSString).appendingPathComponent("outer/inner")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:"); try db.insertFolder(folder)
        let platform = Platform()
        let volume = try #require(URL(fileURLWithPath: nested).resourceValues(forKeys: [.volumeURLKey]).volume)
        let volumeParts = volume.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parentParts = URL(fileURLWithPath: nested).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rootRelative = Array(parentParts.dropFirst(volumeParts.count))
        for (mode, expected) in [("none", [String]()), ("parent", ["inner"]), ("monitored", ["outer", "inner"]), ("root", rootRelative)] {
            let action = makeAction(.upload, .object([
                "upload_protocol": .string("webdavs"), "upload_host": .string("example.com"),
                "upload_username": .string("user"), "upload_remote_path": .string("/incoming"),
                ActionParam.folderStructure: .string(mode)
            ]))
            var rule = makeRule(folderId: folder.id, name: mode, actions: [action]); rule.recursionDepth = nil
            rule.actions[0].ruleId = rule.id
            let preview = (nested as NSString).appendingPathComponent("preview-\(mode).txt")
            try "x".write(toFile: preview, atomically: true, encoding: .utf8)
            let plan = try #require(RuleEngine.previewFile(path: preview, depth: 2, rules: [rule], root: source.path))
            let suffix = expected.isEmpty ? "/incoming" : "/incoming/" + expected.joined(separator: "/")
            #expect(plan.rules.first?.actions.first?.description.contains(suffix) == true)
            let manual = (nested as NSString).appendingPathComponent("manual-\(mode).txt")
            try "x".write(toFile: manual, atomically: true, encoding: .utf8)
            #expect(RuleEngine.run(path: manual, depth: 2, rules: [rule], batchId: mode, root: source.path, platform: platform).history.first?.status == .applied)
            #expect(platform.uploads.last?.relativeFolders == expected)
            try db.insertRule(rule)
            let watched = (nested as NSString).appendingPathComponent("watched-\(mode).txt")
            try "x".write(toFile: watched, atomically: true, encoding: .utf8)
            WatcherCoordinator(db: db, actionPlatform: platform).handle(path: watched)
            #expect(platform.uploads.last?.relativeFolders == expected)
            try db.deleteRule(rule.id)
        }
        let action = makeAction(.upload, .object(["upload_protocol": .string("webdavs"), "upload_host": .string("example.com"), "upload_username": .string("user"), ActionParam.folderStructure: .string("monitored")]))
        let file = (nested as NSString).appendingPathComponent("missing-root.txt")
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(throws: ActionError.self) { try ActionExecutor.plan(action, path: file) }
        #expect(throws: ActionError.self) { try ActionExecutor.execute(action, path: file, platform: platform) }
    }
    @Test func savedCredentialCannotBeReusedForDifferentOrigin() throws {
        func action(host: String = "EXAMPLE.com", port: String = "443", user: String = "user", type: String = "webdavs") -> Action {
            makeAction(.upload, .object(["upload_protocol": .string(type), "upload_host": .string(host),
                "upload_port": .string(port), "upload_username": .string(user), "upload_remote_path": .string("/incoming"),
                "upload_credential_id": .string("public-reference")]))
        }
        let original = action()
        let config = try UploadConfiguration(action: original)
        let secret = "fixture-secret-not-a-user-password"
        let data = try UploadCredentials.encode(secret, configuration: config)
        #expect(try UploadCredentials.decode(data, configuration: UploadConfiguration(action: action(host: "example.COM"))) == secret)
        for changed in [action(host: "attacker.example"), action(port: "444"), action(user: "other"), action(type: "webdav")] {
            #expect(throws: ActionError.self) { try UploadCredentials.decode(data, configuration: UploadConfiguration(action: changed)) }
        }
        let exported = try RuleTransfer.exportForel([makeRule(name: "upload", actions: [original])])
        #expect(!String(decoding: exported, as: UTF8.self).contains(secret))
    }

    @Test func hostRejectsUserinfoAndAcceptsIPv6Literal() throws {
        func config(_ host: String) throws -> UploadConfiguration {
            try UploadConfiguration(action: makeAction(.upload, .object([
                "upload_protocol": .string("webdavs"), "upload_host": .string(host), "upload_username": .string("user")
            ])))
        }
        for host in ["https://user:password@example.com", "user:password@example.com", "example.com%40evil"] {
            #expect(throws: ActionError.self) { try config(host) }
        }
        #expect(try config("::1").host == "[::1]")
        #expect(try config("[::1]").host == "[::1]")
    }
}
