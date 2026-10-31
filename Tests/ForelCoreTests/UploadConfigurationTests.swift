import Foundation
import Testing
@testable import ForelCore

@Suite struct UploadConfigurationTests {
    private final class Platform: ActionPlatform, @unchecked Sendable {
        var uploads: [UploadConfiguration] = []
        func upload(path: String, configuration: UploadConfiguration) throws { uploads.append(configuration) }
        func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws {}
        func showInFinder(path: String, bringToFront: Bool) throws {}
        func notify(text: String, sound: Bool) throws {}
        func pause(seconds: TimeInterval) throws {}
        func trash(path: String) throws -> String { throw ActionError("Unexpected trash") }
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
