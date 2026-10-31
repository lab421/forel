// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421

import Foundation
import Testing
import Darwin
@testable import ForelCore

@Suite struct RuleTransferTests {
    @Test func nativeExportRoundTripsRulesWithFreshIdentifiers() throws {
        let sourceId = UUID().uuidString
        let source = Rule(
            id: sourceId,
            folderId: "source-folder",
            name: "Invoices",
            enabled: true,
            conditionMatch: .any,
            recursionDepth: nil,
            conditions: [Condition(ruleId: sourceId, kind: .name, operator: .contains, value: "Invoice")],
            actions: [Action(ruleId: sourceId, kind: .addTag, params: .object([ActionParam.tags: .stringArray(["Filed"])]), position: 0)]
        )

        let data = try RuleTransfer.exportForel([source])
        let result = try RuleTransfer.importRules(from: data, folderId: "destination-folder")

        #expect(result.issues.isEmpty)
        #expect(result.rules.count == 1)
        #expect(result.rules[0].id != source.id)
        #expect(result.rules[0].folderId == "destination-folder")
        #expect(result.rules[0].conditionMatch == .any)
        #expect(result.rules[0].conditions[0].ruleId == result.rules[0].id)
        #expect(result.rules[0].actions[0].ruleId == result.rules[0].id)
    }

    @Test func hazelImportMapsSupportedPartsAndDisablesIncompleteRules() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: hazelFixture(), format: .binary, options: 0)
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")

        #expect(result.rules.count == 2)
        #expect(result.rules[0].name == "Archive G-code")
        #expect(!result.rules[0].enabled)
        #expect(result.rules[0].conditions.map(\.kind) == [.extension_])
        #expect(result.rules[0].actions.map(\.kind) == [.moveToTrash])
        #expect(!result.rules[1].enabled)
        #expect(result.issues.contains { $0.ruleName == "Needs review" })
    }

    // External corpus: rosskukulinski/hazel-rules at b5671f838c133789678c4817a01d1ddd19b3fc09.
    // Set FOREL_HAZEL_CORPUS to its checkout to run against the original files.
    @Test func publicHazelExportsImportForReviewWhenCorpusIsAvailable() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let samples: [(String, Int)] = [
            ("Downloads.hazelrules", 6),
            ("Statements.hazelrules", 7),
            ("Desktop.hazelrules", 2),
            ("Expenses.hazelrules", 1),
            ("To Evernote.hazelrules", 1),
            ("Incoming Documents.hazelrules", 1),
            ("Spreadsheets.hazelrules", 1),
            ("2012_IITSEC_Booth_1149.hazelrules", 2),
            ("tmp.hazelrules", 2),
            ("VOISUS_TESTING.hazelrules", 1),
            ("Production_spreadsheets_&_Schedules.hazelrules", 1),
            ("MANUALS_ALL.hazelrules", 1),
        ]
        for (file, count) in samples {
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(file))
            let result = try RuleTransfer.importRules(from: data, folderId: "folder")
            #expect(result.rules.count == count, "\(file)")
            #expect(result.rules.allSatisfy { !$0.enabled }, "\(file)")
            #expect(result.rules.allSatisfy { rule in result.issues.contains { $0.ruleName == rule.name } }, "\(file)")
            if file == "Downloads.hazelrules" {
                #expect(result.rules[0].name == "Move Statements to Dropbox")
                #expect(result.rules[0].conditionMatch == .any)
                #expect(result.rules[2].conditionMatch == .all)
            }
            if file == "Expenses.hazelrules" {
                #expect(result.rules[0].conditions.map(\.kind) == [.anyFile])
                #expect(!result.issues.contains { $0.message.contains("condition") })
                #expect(result.rules[0].actions.map(\.kind) == [.syncToFolder])
            }
        }
    }

    // thomasjoulin/hazel-rules at 2d5bc70f1a775218b65db46e3929aa9dae5f19bb.
    @Test func secondPublicHazelCorpusImportsWhenAvailable() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS_2"] else { return }
        for (file, count) in [("Desktop.hazelrules", 2), ("Downloads.hazelrules", 1),
                              ("Movies.hazelrules", 2), ("OldDekstop.hazelrules", 1)] {
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(file))
            let result = try RuleTransfer.importRules(from: data, folderId: "folder")
            #expect(result.rules.count == count, "\(file)")
            #expect(result.rules.allSatisfy { !$0.enabled }, "\(file)")
        }
    }

    // ericteeman/hazelrules at e7efab72435f6b0bf7d697cc4e4c9c0a5f8e08ef.
    @Test func thirdPublicHazelCorpusImportsWhenAvailable() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS_3"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Screen Shots.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")
        #expect(result.rules.count == 1)
        #expect(result.rules[0].name == "Move, Rename, and Add to Clipboard Screen Shots")
        #expect(!result.rules[0].enabled)
    }

    // ptoomey3/family-photo-library at 546307c5fe0aaba91eaab0f4397d7e03aa66357e
    // and ash0080/better-unzip-for-Hazel at dfa94a98b9dc960c230ac199789155014e19caa7.
    @Test func photoAndUnzipExportsPreserveTheirActionsAndPredicates() throws {
        let samples: [(String, String, [[ConditionKind]], [[ActionKind]])] = [
            ("FOREL_HAZEL_PHOTOS", "google_photos.hazelrules", [[.contentType], [.contentType, .contentType]], [[.hazelRecurse], [.runHazelOSA, .moveToFolder, .rename, .moveToFolder]]),
            ("FOREL_HAZEL_UNZIP", "download.hazelrules", [[.contentType], [.extensionInsensitive, .subfolderDepth], [.contentType, .contentType, .extensionInsensitive]], [[.hazelRecurse], [.openDefault, .moveToTrash], [.runHazelShellScript]]),
        ]
        for (variable, filename, conditions, actions) in samples {
            guard let root = ProcessInfo.processInfo.environment[variable] else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(filename))
            let result = try RuleTransfer.importRules(from: data, folderId: "folder")
            #expect(result.rules.count == conditions.count)
            #expect(result.rules.allSatisfy { !$0.enabled })
            #expect(result.rules.allSatisfy { $0.importError == nil })
            #expect(result.rules.map { $0.conditions.map(\.kind) } == conditions)
            #expect(result.rules.map { $0.actions.map(\.kind) } == actions)
        }
    }

    // Public exports at the revisions recorded below. Set each environment
    // variable to the corresponding checkout to run the original files.
    @Test func additionalPublicExportsPreserveRulesAndFlagUnsupportedParts() throws {
        let cases: [(String, String, [String])] = [
            // albatrossflavour/tickler: 5071e3364b51f8877aa508512efae65eccff01df
            ("FOREL_HAZEL_TICKLER", "Downloads.hazelrules", ["Tickler files"]),
            ("FOREL_HAZEL_TICKLER", "tickler.hazelrules", ["Scan folders for files to bring forward", "Move files"]),
            // Jaharmi/archive_osx_installer_app: 5766d4647fa75db8fc5d04571dd534e2cd8ff011
            ("FOREL_HAZEL_INSTALLER", "Applications.hazelrules", ["Archive OS X installer application"]),
            // EvanLovely/drafts-hazel--open-url: 1543f01e0d387d32e1503d08ed56eb057fc89c6c
            ("FOREL_HAZEL_OPEN_URL", "to-open-url.hazelrules", ["Open URL"]),
            // bjango/Bjango-Actions: 0fdc790b4931fd36816e6056dd84c2aa0d3ff054
            ("FOREL_HAZEL_BJANGO", "Hazel Rules/Auto @2x, then move.hazelrules", ["Auto @2x, then move"]),
            ("FOREL_HAZEL_BJANGO", "Hazel Rules/Auto @3x, then move.hazelrules", ["Auto @3x, then move"]),
            ("FOREL_HAZEL_BJANGO", "Hazel Rules/Move into subfolders if # exists.hazelrules", ["Move into subfolders if # exists"]),
        ]
        for (variable, path, names) in cases {
            guard let root = ProcessInfo.processInfo.environment[variable] else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(path))
            let result = try RuleTransfer.importRules(from: data, folderId: "folder")
            #expect(result.rules.map(\.name) == names, "\(path)")
            #expect(result.rules.allSatisfy { !$0.enabled }, "\(path)")
            #expect(result.rules.allSatisfy { rule in result.issues.contains { $0.ruleName == rule.name } }, "\(path)")
            if variable == "FOREL_HAZEL_TICKLER", path == "tickler.hazelrules" {
                #expect(result.rules[0].conditions.map(\.kind) == [.contentType, .subfolderDepth])
                #expect(result.rules[0].actions.map(\.kind) == [.hazelRecurse])
                #expect(result.rules[1].conditions.map(\.kind) == [.conditionGroup, .hazelScriptCondition])
                #expect(result.rules[1].actions.map(\.kind) == [.moveToFolder, .setFinderLabel, .setFinderComment])
                #expect(result.rules[1].importError == nil)
            }
            if variable == "FOREL_HAZEL_INSTALLER" {
                #expect(result.rules.first?.importError == nil)
                #expect(result.rules.first?.actions.map(\.kind) == [.runHazelShellScript])
                #expect(result.rules.first?.actions.first?.params[ActionParam.shellMode]?.stringValue == "external")
            }
            if variable == "FOREL_HAZEL_OPEN_URL" {
                #expect(result.rules.contains { $0.actions.contains { $0.kind == .runHazelShellScript } }, "\(path)")
            }
        }
    }

    @Test func realHazelExtensionConditionsAndMoveRunOnTemporaryFiles() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")
        var rule = try #require(result.rules.first { $0.name == "Downloaded Documents to Dropbox" })
        #expect(!rule.enabled)
        #expect(rule.conditionMatch == .any)
        #expect(rule.conditions.count == 7)
        #expect(rule.actions.map(\.kind) == [.moveToFolder])
        #expect(rule.actions[0].params[ActionParam.destination]?.stringValue?.hasSuffix("/Dropbox/Incoming Documents") == true)
        #expect(rule.actions[0].params[ActionParam.discardDuplicates]?.boolValue == true)

        let directory = TempDir()
        let pdf = directory.file("report.PDF", contents: "document")
        let image = directory.file("photo.png", contents: "image")
        let target = directory.dir("destination")
        rule.enabled = true
        rule.actions[0].params = .object([ActionParam.destination: .string(target), ActionParam.discardDuplicates: .bool(true)])

        let preview = try #require(RuleEngine.previewFile(path: pdf, depth: 0, rules: [rule]))
        #expect(preview.rules[0].actions[0].status == .wouldRun)
        #expect(RuleEngine.previewFile(path: image, depth: 0, rules: [rule]) == nil)
        #expect(FileManager.default.fileExists(atPath: pdf))
        let resultRun = RuleEngine.run(path: pdf, depth: 0, rules: [rule], batchId: "test")
        #expect(resultRun.history.count == 1)
        #expect(resultRun.history[0].status == .applied)
        #expect(FileManager.default.fileExists(atPath: (target as NSString).appendingPathComponent("report.PDF")))
    }

    @Test func realHazelRelativeDateConditionMatchesANewFile() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")
        let rule = try #require(result.rules.first { $0.name == "Newly Added Files" })
        let condition = try #require(rule.conditions.first)
        #expect(condition.kind == .dateAdded)
        #expect(condition.operator == .hazelWithinLast)
        #expect(condition.value == "1 day")
        #expect(!rule.enabled)
        let directory = TempDir()
        let file = directory.file("new.txt")
        #expect(ConditionEvaluator.evaluate(condition, path: file))
        #expect(rule.actions.first?.kind == .setFinderLabel)
        #expect(rule.actions.first?.params[ActionParam.color]?.stringValue == "Blue")
    }

    @Test func realHazelOldDMGRuleDoesNotTrashNewDownloads() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads.hazelrules"))
        let directory = TempDir()
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first {
            $0.name == "Remove old DMG files"
        })
        #expect(rule.conditions.map(\.kind) == [.extension_, .dateAdded])
        #expect(rule.conditions.map(\.operator) == [.contains, .beforeToday])
        #expect(rule.actions.map(\.kind) == [.moveToTrash])
        #expect(RuleValidator.validate(rule.conditions).isEmpty)
        rule.enabled = true
        let file = directory.file("recent.DMG", contents: "test")
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]) == nil)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "dmg").history.isEmpty)
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: file)
        #expect(try db.listHistory().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func realHazelScreenshotRuleWaitsForOldModificationDateAcrossExecutionPaths() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Desktop.hazelrules"))
        let source = TempDir()
        let destination = TempDir()
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let imported = try RuleTransfer.importRules(from: data, folderId: folder.id)
        var rule = try #require(imported.rules.first { $0.name == "Move screenshots to /pictures/screenshots" })
        #expect(!imported.issues.contains { $0.ruleName == rule.name && $0.message.contains("skipped") })
        #expect(rule.conditions.contains {
            guard $0.kind == .conditionGroup, let group = ConditionGroup.decode($0.value) else { return false }
            return group.match == .none && group.target == .current && group.conditions.count == 1 &&
                group.conditions[0].kind == .dateModified && group.conditions[0].operator == .hazelWithinLast && group.conditions[0].value == "1 hour"
        })
        rule.enabled = true
        rule.actions[0].params = .object([ActionParam.destination: .string(destination.path)])

        let preview = source.file("Screen Shot preview.png", contents: "preview")
        let manual = source.file("Screen Shot manual.png", contents: "manual")
        let automatic = source.file("Screen Shot watcher.png", contents: "automatic")
        let recent = source.file("Screen Shot recent.png", contents: "recent")
        let nonmatch = source.file("other.png", contents: "other")
        for file in [preview, manual, automatic, nonmatch] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: file)
        }
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun)
        #expect(RuleEngine.previewFile(path: recent, depth: 0, rules: [rule]) == nil)
        #expect(RuleEngine.previewFile(path: nonmatch, depth: 0, rules: [rule]) == nil)
        #expect(FileManager.default.fileExists(atPath: preview))
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "screenshot").history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("Screen Shot manual.png")))
        try db.insertRule(rule)
        let watcher = WatcherCoordinator(db: db)
        watcher.handle(path: automatic)
        watcher.handle(path: recent)
        #expect(try db.listHistory().count == 1)
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("Screen Shot watcher.png")))
        #expect(FileManager.default.fileExists(atPath: recent))
    }

    @Test func realHazelTrashRulesRunEndToEndInAnIsolatedHome() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let first = environment["FOREL_HAZEL_CORPUS"],
              let second = environment["FOREL_HAZEL_CORPUS_2"], let trashPath = testTrashDirectory() else { return }
        let trash = URL(fileURLWithPath: trashPath)
        for (root, export, name, suffix) in [
            (first, "Downloads.hazelrules", "Remove old DMG files", "dmg"),
            (first, "Downloads.hazelrules", "Old Files", "txt"),
            (first, "tmp.hazelrules", "Delete old files", "txt"),
            (second, "Downloads.hazelrules", "Old Files", "txt"),
            (second, "Desktop.hazelrules", "Delete screenshots", "png"),
            (second, "OldDekstop.hazelrules", "Delete old", "txt"),
        ] {
            let source = TempDir()
            let folder = WatchedFolder(path: source.path)
            let db = try Database(path: ":memory:")
            try db.insertFolder(folder)
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(export))
            let imported = try RuleTransfer.importRules(from: data, folderId: folder.id)
            var rule = try #require(imported.rules.first { $0.name == name })
            #expect(!imported.issues.contains { $0.ruleName == name && ($0.message.contains("skipped") || $0.message.contains("not imported")) })
            #expect(rule.actions.map(\.kind) == [.moveToTrash])
            rule.enabled = true
            let prefix = (name == "Delete screenshots" ? "Screen Shot " : "") + UUID().uuidString
            let preview = source.file("\(prefix)-preview.\(suffix)", contents: "preview")
            let manual = source.file("\(prefix)-manual.\(suffix)", contents: "manual")
            let automatic = source.file("\(prefix)-watcher.\(suffix)", contents: "automatic")
            let recent = source.file("\(prefix)-recent.\(suffix)", contents: "recent")
            for path in [preview, manual, automatic] {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86400)], ofItemAtPath: path)
                var attributes = attrlist()
                attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attributes.commonattr = UInt32(ATTR_CMN_ADDEDTIME)
                var old = timespec(tv_sec: Int(Date().addingTimeInterval(-90 * 86400).timeIntervalSince1970), tv_nsec: 0)
                let rc = withUnsafeMutablePointer(to: &old) { setattrlist(path, &attributes, $0, MemoryLayout<timespec>.size, 0) }
                #expect(rc == 0)
            }
            #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun, "\(name)")
            #expect(RuleEngine.previewFile(path: recent, depth: 0, rules: [rule]) == nil, "\(name)")
            #expect(FileManager.default.fileExists(atPath: preview))
            #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "corpus-trash").history.first?.status == .applied, "\(name)")
            #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent((manual as NSString).lastPathComponent).path))
            try db.insertRule(rule)
            let watcher = WatcherCoordinator(db: db)
            watcher.handle(path: automatic)
            watcher.handle(path: recent)
            #expect(try db.listHistory().count == 1, "\(name)")
            #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent((automatic as NSString).lastPathComponent).path))
            #expect(FileManager.default.fileExists(atPath: recent))
        }
    }

    @Test func realHazelLastOpenedMoveRulesRunAcrossExecutionPaths() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let first = environment["FOREL_HAZEL_CORPUS"], let second = environment["FOREL_HAZEL_CORPUS_2"] else { return }
        for (root, export, name) in [(first, "Desktop.hazelrules", "Old files to temp"), (second, "Desktop.hazelrules", "Move old files")] {
            let source = TempDir()
            let destination = TempDir()
            let folder = WatchedFolder(path: source.path)
            let db = try Database(path: ":memory:")
            try db.insertFolder(folder)
            let imported = try RuleTransfer.importRules(from: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(export)), folderId: folder.id)
            var rule = try #require(imported.rules.first { $0.name == name })
            #expect(rule.importError == nil)
            #expect(rule.conditions.contains { $0.kind == .dateLastOpened })
            rule.enabled = true
            rule.actions[0].params = .object([ActionParam.destination: .string(destination.path)])
            let preview = source.file("preview.txt", contents: "preview")
            let manual = source.file("manual.txt", contents: "manual")
            let automatic = source.file("watcher.txt", contents: "watcher")
            let recent = source.file("recent.txt", contents: "recent")
            for path in [preview, manual, automatic] {
                let old = Date().addingTimeInterval(-90 * 86400)
                try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: path)
                var attributes = attrlist()
                attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attributes.commonattr = UInt32(ATTR_CMN_ADDEDTIME)
                var timestamp = timespec(tv_sec: Int(old.timeIntervalSince1970), tv_nsec: 0)
                #expect(withUnsafeMutablePointer(to: &timestamp) { setattrlist(path, &attributes, $0, MemoryLayout<timespec>.size, 0) } == 0)
            }
            #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun, "\(name)")
            #expect(RuleEngine.previewFile(path: recent, depth: 0, rules: [rule]) == nil, "\(name)")
            let result = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "last-opened")
            #expect(result.history.first?.status == .applied, "\(name)")
            try db.insertRule(rule)
            WatcherCoordinator(db: db).handle(path: automatic)
            #expect(try db.listHistory().first?.status == .applied, "\(name)")
            #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("manual.txt")))
            #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("watcher.txt")))
            #expect(FileManager.default.fileExists(atPath: recent))
        }
    }

    @Test func realHazelLastOpenedAfterModifiedConditionIsImported() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS_2"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Movies.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")
        let rule = try #require(result.rules.first { $0.name == "Seen" })
        #expect(rule.importError == nil)
        #expect(rule.conditions.contains { $0.kind == .dateLastOpened && $0.operator == .afterLastModified })
        #expect(RuleValidator.validate(rule.conditions).isEmpty)
    }

    @Test func realHazelLabelRulesRunOnUntaggedFilesAcrossExecutionPaths() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        for (export, name, color, labelNumber, old) in [
            ("Downloads.hazelrules", "Newly Added Files", "Blue", 4, false),
            ("Downloads.hazelrules", "No Longer New Files", "Red", 6, true),
            ("tmp.hazelrules", "Color_to_be_deleted", "Red", 6, true),
        ] {
            let source = TempDir()
            let folder = WatchedFolder(path: source.path)
            let db = try Database(path: ":memory:")
            try db.insertFolder(folder)
            let imported = try RuleTransfer.importRules(from: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(export)), folderId: folder.id)
            var rule = try #require(imported.rules.first { $0.name == name })
            #expect(rule.importError == nil)
            #expect(rule.actions.map(\.kind) == [.setFinderLabel])
            #expect(rule.actions.first?.params[ActionParam.color]?.stringValue == color)
            #expect(imported.issues.contains { $0.ruleName == name && $0.message.contains("color labels") })
            rule.enabled = true
            let preview = source.file("preview.txt")
            let manual = source.file("manual.txt")
            let automatic = source.file("watcher.txt")
            if old {
                for path in [preview, manual, automatic] {
                    var attributes = attrlist()
                    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                    attributes.commonattr = UInt32(ATTR_CMN_ADDEDTIME)
                    var timestamp = timespec(tv_sec: Int(Date().addingTimeInterval(-90 * 86400).timeIntervalSince1970), tv_nsec: 0)
                    #expect(withUnsafeMutablePointer(to: &timestamp) { setattrlist(path, &attributes, $0, MemoryLayout<timespec>.size, 0) } == 0)
                }
            }
            #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun, "\(name)")
            #expect(try URL(fileURLWithPath: preview).resourceValues(forKeys: [.labelNumberKey]).labelNumber == 0)
            let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "label")
            let entry = try #require(run.history.first)
            #expect(entry.status == .applied, "\(name)")
            #expect(try URL(fileURLWithPath: manual).resourceValues(forKeys: [.labelNumberKey]).labelNumber == labelNumber)
            #expect(ConditionEvaluator.evaluate(makeCondition(.colorLabel, .is, color), path: manual))
            #expect(!ConditionEvaluator.evaluate(makeCondition(.colorLabel, .isNot, color), path: manual))
            try db.insertRule(rule)
            WatcherCoordinator(db: db).handle(path: automatic)
            #expect(try db.listHistory().first?.status == .applied)
            #expect(try URL(fileURLWithPath: automatic).resourceValues(forKeys: [.labelNumberKey]).labelNumber == labelNumber)
            try ActionExecutor.revert(Undo.fromJSON(entry.undo))
            #expect(try URL(fileURLWithPath: manual).resourceValues(forKeys: [.labelNumberKey]).labelNumber == 0)
        }
    }

    @Test func importedLabelPreservesExistingTagsAndContinuesActions() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads.hazelrules"))
        let directory = TempDir()
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first { $0.name == "Newly Added Files" })
        rule.enabled = true
        rule.actions.append(makeAction(.addTag, .object([ActionParam.tags: .stringArray(["After"])]), position: 1, ruleId: rule.id))
        let preview = directory.file("preview.txt")
        let manual = directory.file("manual.txt")
        let watched = directory.file("watcher.txt")
        for path in [preview, manual, watched] { try FinderTags.apply(path, tag: "Project", add: true) }
        let plan = try #require(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]))
        #expect(plan.rules.first?.actions.map(\.status) == [.wouldRun, .wouldRun])
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "tagged-label")
        #expect(run.history.map(\.status) == [.applied, .applied])
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().count == 2)
        #expect(try db.listHistory().allSatisfy { $0.status == .applied })
        for path in [manual, watched] {
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(FinderTags.read(path).contains("Project"))
            #expect(FinderTags.read(path).contains("After"))
            #expect(try ActionExecutor.finderLabel(path) != 0)
        }
        #expect(FinderTags.read(preview) == ["Project"])
    }

    @Test func importedLabelAcceptsEmptyTagsAndRejectsMalformedTags() throws {
        let directory = TempDir()
        let action = makeAction(.setFinderLabel, .object([ActionParam.color: .string("Blue")]))
        let empty = directory.file("empty.txt")
        try FinderTags.write(empty, [])
        #expect(try ActionExecutor.plan(action, path: empty).status == .wouldRun)
        let applied = try ActionExecutor.execute(action, path: empty)
        #expect(try URL(fileURLWithPath: empty).resourceValues(forKeys: [.labelNumberKey]).labelNumber == 4)
        try ActionExecutor.revert(applied.undo)
        #expect(try URL(fileURLWithPath: empty).resourceValues(forKeys: [.labelNumberKey]).labelNumber == 0)

        let malformed = directory.file("malformed.txt")
        let invalid = Data("not a plist".utf8)
        #expect(invalid.withUnsafeBytes { setxattr(malformed, FinderTags.xattrName, $0.baseAddress, $0.count, 0, 0) } == 0)
        let rule = makeRule(name: "label", actions: [action, makeAction(.moveToTrash, .object([:]), position: 1)])
        let preview = try #require(RuleEngine.previewFile(path: malformed, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.actions.map(\.status) == [.blocked])
        let run = RuleEngine.run(path: malformed, depth: 0, rules: [rule], batchId: "malformed-label")
        #expect(run.history.map(\.status) == [.failed])
        #expect(FileManager.default.fileExists(atPath: malformed))
    }

    @Test func realHazelSyncRulesRunOnTemporaryFilesAcrossExecutionPaths() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        for (export, name, ext) in [
            ("Expenses.hazelrules", "Sync Expenses", "txt"),
            ("MANUALS_ALL.hazelrules", "Sync all manuals", "txt"),
            ("VOISUS_TESTING.hazelrules", "Voisus_Testing Sync", "txt"),
            ("Spreadsheets.hazelrules", "Copy PO Spreadsheets", "xls"),
            ("Production_spreadsheets_&_Schedules.hazelrules", "Sync Excel Spreadsheets", "xlsx"),
            ("2012_IITSEC_Booth_1149.hazelrules", "Duplicate Everything", "xlsx"),
        ] {
            let source = TempDir()
            let destination = TempDir()
            let folder = WatchedFolder(path: source.path)
            let db = try Database(path: ":memory:")
            try db.insertFolder(folder)
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(export))
            let imported = try RuleTransfer.importRules(from: data, folderId: folder.id)
            var rule = try #require(imported.rules.first { $0.name == name })
            #expect(rule.actions.map(\.kind) == [.syncToFolder], "\(name)")
            #expect(!imported.issues.contains { $0.ruleName == name && $0.message.contains("skipped") }, "\(name)")
            rule.enabled = true
            rule.actions[0].params = .object([ActionParam.destination: .string(destination.path)])
            let preview = source.file("preview.\(ext)", contents: "preview")
            let manual = source.file("manual.\(ext)", contents: "new data")
            let automatic = source.file("watcher.\(ext)", contents: "watcher")
            _ = destination.file("manual.\(ext)", contents: "old data")
            #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun, "\(name)")
            #expect(!FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("preview.\(ext)")))
            let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "sync")
            #expect(run.history.first?.status == .applied, "\(name): \(run.history.first?.message ?? "")")
            #expect(try String(contentsOfFile: (destination.path as NSString).appendingPathComponent("manual.\(ext)"), encoding: .utf8) == "new data")
            #expect(FileManager.default.fileExists(atPath: manual))
            try db.insertRule(rule)
            WatcherCoordinator(db: db).handle(path: automatic)
            #expect(try db.listHistory().first?.status == .applied, "\(name)")
            #expect(try String(contentsOfFile: (destination.path as NSString).appendingPathComponent("watcher.\(ext)"), encoding: .utf8) == "watcher")
        }
    }

    @Test func realHazelSyncMirrorsFoldersAndKeepsOtherDestinationItems() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Expenses.hazelrules"))
        let source = TempDir()
        let destination = TempDir()
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first)
        rule.enabled = true
        rule.actions[0].params = .object([ActionParam.destination: .string(destination.path)])
        let unrelated = destination.file("unrelated.txt", contents: "keep")
        for name in ["preview", "manual", "watcher"] {
            let input = source.dir(name)
            let output = destination.dir(name)
            try "current".write(toFile: (input as NSString).appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
            try "old".write(toFile: (output as NSString).appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
            try "delete".write(toFile: (output as NSString).appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
        }
        let preview = (source.path as NSString).appendingPathComponent("preview")
        let manual = (source.path as NSString).appendingPathComponent("manual")
        let watcherPath = (source.path as NSString).appendingPathComponent("watcher")
        let previewResult = try #require(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]))
        #expect(previewResult.rules.first?.actions.first?.description.contains("removes destination items") == true)
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("preview/stale.txt")))
        let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "sync-folder")
        #expect(run.history.first?.status == .applied, "\(run.history.first?.message ?? "")")
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watcherPath)
        #expect(try db.listHistory().first?.status == .applied)
        for name in ["manual", "watcher"] {
            #expect(!FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("\(name)/stale.txt")))
            #expect(try String(contentsOfFile: (destination.path as NSString).appendingPathComponent("\(name)/keep.txt"), encoding: .utf8) == "current")
        }
        #expect(FileManager.default.fileExists(atPath: unrelated))
        #expect(FileManager.default.fileExists(atPath: (source.path as NSString).appendingPathComponent("manual/keep.txt")))
        let overlapping = makeAction(.syncToFolder, .object([ActionParam.destination: .string(manual)]))
        #expect(throws: ActionError.self) { try ActionExecutor.plan(overlapping, path: manual) }
        #expect(throws: ActionError.self) { try ActionExecutor.execute(overlapping, path: manual) }
        let other = TempDir()
        let linkSource = source.dir("linked")
        let linkDestination = (destination.path as NSString).appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(atPath: linkDestination, withDestinationPath: other.path)
        #expect(throws: ActionError.self) { try ActionExecutor.plan(rule.actions[0], path: linkSource) }
        #expect(throws: ActionError.self) { try ActionExecutor.execute(rule.actions[0], path: linkSource) }
    }

    @Test func publicRulesImportWithoutOmittedParts() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let first = environment["FOREL_HAZEL_CORPUS"],
              let second = environment["FOREL_HAZEL_CORPUS_2"],
              let bjango = environment["FOREL_HAZEL_BJANGO"], testTrashDirectory() != nil else { return }
        var total = 0
        var blocked = 0
        for root in [first, second, (bjango as NSString).appendingPathComponent("Hazel Rules")] {
            let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "hazelrules" }
            for export in files {
                let data = try Data(contentsOf: export)
                let directory = TempDir()
                let destination = TempDir()
                let folder = WatchedFolder(path: directory.path)
                let imported = try RuleTransfer.importRules(from: data, folderId: folder.id)
                for var rule in imported.rules {
                    total += 1
                    guard let error = rule.importError else { continue }
                    blocked += 1
                    #expect(!rule.enabled)
                    #expect(!error.isEmpty)
                    rule.enabled = true
                    for index in rule.actions.indices where [.moveToFolder, .copyToFolder, .syncToFolder].contains(rule.actions[index].kind) {
                        rule.actions[index].params = .object([ActionParam.destination: .string(destination.path)])
                    }
                    let name = UUID().uuidString
                    let preview = directory.file("\(name)-preview.txt", contents: "preview")
                    let manual = directory.file("\(name)-manual.txt", contents: "manual")
                    let watched = directory.file("\(name)-watcher.txt", contents: "watcher")
                    let result = try #require(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]))
                    #expect(result.rules.first?.actions.first?.status == .blocked, "\(export.lastPathComponent): \(rule.name)")
                    #expect(result.rules.first?.actions.first?.description.contains(error) == true)
                    let run = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "incomplete")
                    #expect(run.history.count == 1)
                    #expect(run.history.first?.status == .failed)
                    #expect(run.history.first?.actionKind == .importError)
                    #expect(run.history.first?.message?.contains(error) == true)
                    let db = try Database(path: ":memory:")
                    try db.insertFolder(folder)
                    try db.insertRule(rule)
                    #expect(try db.listRules(folderId: folder.id).first?.importError == error)
                    let serialized = try RuleTransfer.exportForel([rule])
                    let reimported = try #require(RuleTransfer.importRules(from: serialized, folderId: folder.id).rules.first)
                    #expect(reimported.importError == error)
                    #expect(!reimported.enabled)
                    WatcherCoordinator(db: db).handle(path: watched)
                    let history = try db.listHistory()
                    #expect(history.count == 1)
                    #expect(history.first?.status == .failed)
                    #expect(history.first?.message?.contains(error) == true)
                    for path in [preview, manual, watched] { #expect(FileManager.default.fileExists(atPath: path)) }
                    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
                }
            }
        }
        #expect(total == 35)
        #expect(blocked == 0)
    }

    @Test func incompleteRuleCannotRunSupportedDestructiveAction() throws {
        var fixture = hazelFixture()
        var objects = try #require(fixture["$objects"] as? [Any])
        objects[9] = ["$class": ["CF$UID": 4], "NS.objects": [["CF$UID": 10], ["CF$UID": 14]]]
        fixture["$objects"] = objects
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        let dir = TempDir()
        let folder = WatchedFolder(path: dir.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first)
        let reason = try #require(rule.importError)
        #expect(rule.actions.map(\.kind) == [.moveToTrash])
        #expect(!rule.enabled)
        rule.enabled = true
        try db.insertRule(rule)
        let saved = try #require(db.listRules(folderId: folder.id).first)
        #expect(saved.importError == reason)
        let restored = try #require(RuleTransfer.importRules(from: RuleTransfer.exportForel([saved]), folderId: folder.id).rules.first)
        #expect(restored.importError == reason && !restored.enabled)
        let preview = dir.file("preview.gcode"), manual = dir.file("manual.gcode"), watched = dir.file("watcher.gcode")
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .blocked)
        let result = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "unsafe")
        #expect(result.history.first?.status == .failed && result.history.first?.actionKind == .importError)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(try db.listHistory().first?.status == .failed)
        #expect([preview, manual, watched].allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    @Test func evidencedHazelStaticTagArraysAreImported() throws {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        for (name, kind) in [("HazelAddTagsAction", ActionKind.addTag), ("HazelRemoveTagsAction", .removeTag)] {
            var fixture = hazelFixture()
            var objects = try #require(fixture["$objects"] as? [Any])
            objects[10] = ["$class": uid(17), "parameter": uid(18), "options": uid(20)]
            objects += [["$classname": name], ["$class": uid(19), "NS.objects": ["ForelFixture"]], ["$classname": "NSArray"], ["$class": uid(21), "NS.keys": [], "NS.objects": []], ["$classname": "NSDictionary"]]
            fixture["$objects"] = objects
            let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
            let rule = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
            #expect(rule.importError == nil)
            let action = try #require(rule.actions.first)
            #expect(action.kind == kind)
            #expect(action.params[ActionParam.tags]?.arrayValue == [.string("ForelFixture")])
        }
    }

    @Test func oracleEvidencedSimpleActionsAreImportedAndUnknownOptionsBlocked() throws {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        for (name, kind) in [("HazelArchiveAction", ActionKind.archive), ("HazelUnarchiveAction", .uncompress), ("HazelNullAction", .ignore)] {
            for extra in [false, true] {
                var fixture = hazelFixture()
                var objects = try #require(fixture["$objects"] as? [Any])
                objects[10] = ["$class": uid(17), "parameter": uid(0), "options": uid(18)]
                objects += [["$classname": name], ["$class": uid(19), "NS.keys": extra ? ["unknown"] : [], "NS.objects": extra ? [1] : []], ["$classname": "NSDictionary"]]
                fixture["$objects"] = objects
                let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
                let rule = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
                if extra { #expect(rule.importError != nil) }
                else { #expect(rule.importError == nil); #expect(rule.actions.first?.kind == kind) }
            }
        }
    }

    @Test func evidencedHazelLockAndExtensionParametersAreImported() throws {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        for (name, kind) in [("HazelFinderLockAction", ActionKind.setLocked), ("HazelHideExtensionAction", .setExtensionHidden)] {
            for value in [0, 1, 2] {
                var fixture = hazelFixture()
                var objects = try #require(fixture["$objects"] as? [Any])
                objects[10] = ["$class": uid(17), "parameter": value, "options": uid(18)]
                objects += [["$classname": name], ["$class": uid(19), "NS.keys": [], "NS.objects": []], ["$classname": "NSDictionary"]]
                fixture["$objects"] = objects
                let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
                let rule = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
                if value == 2 { #expect(rule.importError != nil); continue }
                #expect(rule.importError == nil)
                let action = try #require(rule.actions.first)
                #expect(action.kind == kind)
                #expect(action.params[ActionParam.enabled]?.boolValue == (value == 1))
                let dir = TempDir(), file = dir.file("example.txt")
                var url = URL(fileURLWithPath: file)
                var initial = URLResourceValues()
                if kind == .setLocked { initial.isUserImmutable = value == 0 }
                else { initial.hasHiddenExtension = value == 0 }
                try url.setResourceValues(initial)
                _ = try ActionExecutor.execute(action, path: file)
                let values = try url.resourceValues(forKeys: [.isUserImmutableKey, .hasHiddenExtensionKey])
                #expect((kind == .setLocked ? values.isUserImmutable : values.hasHiddenExtension) == (value == 1))
                if kind == .setLocked && value == 1 { try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
            }
        }
    }

    @Test func evidencedHazelMoveConflictAndStructureOptionsAreImported() throws {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        for (conflict, expectedConflict) in [(0, "rename"), (1, "replace"), (2, "discard")] {
            for (structure, expectedStructure) in [(0, "none"), (1, "parent"), (2, "monitored"), (3, "root")] {
                var fixture = hazelFixture()
                var objects = try #require(fixture["$objects"] as? [Any])
                objects[10] = ["$class": uid(17), "parameter": uid(18), "options": uid(20)]
                objects += [
                    ["$classname": "HazelMoveAction"],
                    ["$class": uid(19), "path": "/tmp/destination"],
                    ["$classname": "HazelConcreteFolder"],
                    ["$class": uid(21), "NS.keys": ["replaceExisting", "keepFolderStructure", "throwAwayDupes"], "NS.objects": [conflict, structure, 0]],
                    ["$classname": "NSDictionary"],
                ]
                fixture["$objects"] = objects
                let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
                let imported = try RuleTransfer.importRules(from: data, folderId: "f")
                let rule = try #require(imported.rules.first)
                #expect(rule.importError == nil)
                let action = try #require(rule.actions.first)
                #expect(action.params[ActionParam.onConflict]?.stringValue ?? "rename" == expectedConflict)
                #expect(action.params[ActionParam.folderStructure]?.stringValue ?? "none" == expectedStructure)
            }
        }
    }

    @Test func oracleEvidencedCopyAndAliasParametersAreImported() throws {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        for (name, conflict, expected) in [("HazelCopyAction", 0, "rename"), ("HazelCopyAction", 1, "replace"), ("HazelCopyAction", 2, "skip"), ("HazelCreateAliasAction", 0, "rename")] {
            var fixture = hazelFixture()
            var objects = try #require(fixture["$objects"] as? [Any])
            objects[10] = ["$class": uid(17), "parameter": uid(18), "options": uid(20)]
            let keys = name == "HazelCopyAction" ? ["replaceExisting", "keepFolderStructure", "throwAwayDupes"] : []
            let values = name == "HazelCopyAction" ? [conflict, 2, 1] : []
            objects += [["$classname": name], ["$class": uid(19), "path": "/tmp/destination"], ["$classname": "HazelConcreteFolder"], ["$class": uid(21), "NS.keys": keys, "NS.objects": values], ["$classname": "NSDictionary"]]
            fixture["$objects"] = objects
            let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
            let rule = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
            #expect(rule.importError == nil)
            let action = try #require(rule.actions.first)
            #expect(action.kind == (name == "HazelCopyAction" ? .copyToFolder : .makeAlias))
            #expect(action.params[ActionParam.destination]?.stringValue == "/tmp/destination")
            if name == "HazelCopyAction" {
                #expect(action.params[ActionParam.onConflict]?.stringValue ?? "rename" == expected)
                #expect(action.params[ActionParam.folderStructure]?.stringValue == "monitored")
                #expect(action.params[ActionParam.skipDuplicates]?.boolValue == true)
            }
        }
    }

    @Test func oracleEvidencedChosenApplicationIsImported() throws {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        for front in [0, 1] {
            var fixture = hazelFixture()
            var objects = try #require(fixture["$objects"] as? [Any])
            objects[10] = ["$class": uid(17), "parameter": uid(18), "options": uid(22)]
            objects += [
                ["$classname": "HazelOpenAction"], ["$class": uid(19), "alias": uid(20)], ["$classname": "HazelAppData"],
                ["$class": uid(21), "path": "/Applications/Example.app", "type": 0], ["$classname": "NoodleFileAlias"],
                ["$class": uid(23), "NS.keys": ["bringFront"], "NS.objects": [front]], ["$classname": "NSDictionary"]
            ]
            fixture["$objects"] = objects
            let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
            let rule = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
            #expect(rule.importError == nil)
            let action = try #require(rule.actions.first)
            #expect(action.kind == .openApplication)
            #expect(action.params[ActionParam.applicationPath]?.stringValue == "/Applications/Example.app")
            #expect(action.params[ActionParam.passFileToApplication]?.boolValue == true)
            #expect(action.params[ActionParam.bringToFront]?.boolValue == (front == 1))
        }
    }

    @Test func oracleEvidencedPauseMeasurementsAreImported() throws {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        for (unit, dimension, expected) in [("Second", "time", 2.0), ("Minute", "time", 120.0), ("Hour", "time", 7200.0), ("Month", "calendar", -1.0)] {
            var fixture = hazelFixture()
            var objects = try #require(fixture["$objects"] as? [Any])
            objects[10] = ["$class": uid(17), "parameter": uid(18), "options": uid(22)]
            objects += [
                ["$classname": "HazelPauseAction"], ["$class": uid(19), "amount": 2, "unit": uid(20)], ["$classname": "NoodleMeasurement"],
                ["$class": uid(21), "name": unit, "dimension": dimension], ["$classname": "NoodleUnit"],
                ["$class": uid(23), "NS.keys": [], "NS.objects": []], ["$classname": "NSDictionary"]
            ]
            fixture["$objects"] = objects
            let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
            let rule = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
            if expected < 0 { #expect(rule.importError != nil); continue }
            #expect(rule.importError == nil)
            let action = try #require(rule.actions.first)
            #expect(action.kind == .pause)
            #expect(Double(action.params[ActionParam.durationSeconds]?.stringValue ?? "") == expected)
        }
    }

    @Test func oracleEvidencedRevealOptionsAreImported() throws {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        for front in [0, 1] {
            var fixture = hazelFixture()
            var objects = try #require(fixture["$objects"] as? [Any])
            objects[10] = ["$class": uid(17), "parameter": uid(0), "options": uid(18)]
            objects += [["$classname": "HazelRevealAction"], ["$class": uid(19), "NS.keys": ["bringFront"], "NS.objects": [front]], ["$classname": "NSDictionary"]]
            fixture["$objects"] = objects
            let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
            let rule = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
            #expect(rule.importError == nil)
            let action = try #require(rule.actions.first)
            #expect(action.kind == .showInFinder)
            #expect(action.params[ActionParam.bringToFront]?.boolValue == (front == 1))
        }
    }

    @Test func oracleEvidencedDefaultLibraryImportsAreImportedWithoutLaunchingApps() throws {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        for (name, library) in [("HazelPhotosAction", "photos"), ("HazelTVAction", "tv"), ("HazeliTunesAction", "music")] {
            var fixture = hazelFixture()
            var objects = try #require(fixture["$objects"] as? [Any])
            objects[10] = ["$class": uid(17), "parameter": uid(0), "options": uid(18)]
            objects += [["$classname": name], ["$class": uid(19), "NS.keys": [], "NS.objects": []], ["$classname": "NSDictionary"]]
            fixture["$objects"] = objects
            let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
            let rule = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
            #expect(rule.importError == nil)
            let action = try #require(rule.actions.first)
            #expect(action.kind == .importToLibrary)
            #expect(action.params[ActionParam.libraryType]?.stringValue == library)
            #expect(action.params[ActionParam.onConflict]?.stringValue == "rename")
        }
    }

    @Test func oracleEvidencedShortcutIdentifierIsImportedWithoutRunningIt() throws {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        let identifier = "00000000-0000-0000-0000-000000000001"
        var fixture = hazelFixture()
        var objects = try #require(fixture["$objects"] as? [Any])
        objects[10] = ["$class": uid(17), "parameter": uid(18), "options": uid(20)]
        objects += [["$classname": "HazelShortcutAction"], ["$class": uid(19), "identifier": identifier, "name": "Example"], ["$classname": "HazelShortcutsEventsShortcut"], ["$class": uid(21), "NS.keys": [], "NS.objects": []], ["$classname": "NSDictionary"]]
        fixture["$objects"] = objects
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        let rule = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
        #expect(rule.importError == nil)
        let action = try #require(rule.actions.first)
        #expect(action.kind == .runShortcut)
        #expect(action.params[ActionParam.shortcutName]?.stringValue == identifier)
        #expect(ShortcutRunner.arguments(name: identifier, input: .file("/tmp/file")) == ["run", identifier, "--input-path", "/tmp/file"])
    }

    @Test func oracleEvidencedAutomatorAliasIsImportedWithoutRunningIt() throws {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        var fixture = hazelFixture()
        var objects = try #require(fixture["$objects"] as? [Any])
        objects[10] = ["$class": uid(17), "parameter": uid(18), "options": uid(20)]
        objects += [["$classname": "HazelAutomatorAction"], ["$class": uid(19), "path": "/tmp/example.workflow", "type": 0], ["$classname": "NoodleFileAlias"], ["$class": uid(21), "NS.keys": [], "NS.objects": []], ["$classname": "NSDictionary"]]
        fixture["$objects"] = objects
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        let rule = try #require(RuleTransfer.importRules(from: data, folderId: "f").rules.first)
        #expect(rule.importError == nil)
        let action = try #require(rule.actions.first)
        #expect(action.kind == .runWorkflow)
        #expect(action.params[ActionParam.workflowPath]?.stringValue == "/tmp/example.workflow")
    }

    @Test func unrecognizedHazelFieldsAreReportedAndBlockExecution() throws {
        var fixture = hazelFixture()
        var objects = try #require(fixture["$objects"] as? [Any])
        var rawRule = try #require(objects[5] as? [String: Any])
        rawRule["futureBehavior"] = true; objects[5] = rawRule
        var rawAction = try #require(objects[10] as? [String: Any])
        rawAction["futureOption"] = true; objects[10] = rawAction
        var predicate = try #require(objects[8] as? [String: Any])
        var op = try #require(predicate["NSPredicateOperator"] as? [String: Any])
        op["futureOption"] = true; predicate["NSPredicateOperator"] = op; objects[8] = predicate
        fixture["$objects"] = objects
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        let result = try RuleTransfer.importRules(from: data, folderId: "f")
        let error = try #require(result.rules.first?.importError)
        #expect(error.contains("rule field futureBehavior"))
        #expect(error.contains("action field futureOption"))
        #expect(error.contains("condition field operator.futureOption"))
        #expect(result.rules.first?.enabled == false)
    }

    @Test func modernRuleOptionsAreInspectedRatherThanSilentlyDiscarded() throws {
        var fixture = hazelFixture()
        var objects = try #require(fixture["$objects"] as? [Any])
        var rawRule = try #require(objects[5] as? [String: Any])
        rawRule["options"] = ["CF$UID": 17]; objects[5] = rawRule
        objects.append(["$class": ["CF$UID": 18], "textRecognition": 1, "hasStoredDocumentPasswordStored": false])
        objects.append(["$classname": "HazelRuleOptions"])
        fixture["$objects"] = objects
        let harmless = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        #expect(try RuleTransfer.importRules(from: harmless, folderId: "f").rules.first?.importError == nil)
        var options = try #require(objects[17] as? [String: Any]); options["newPolicy"] = true; objects[17] = options
        fixture["$objects"] = objects
        let unknown = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        #expect(try RuleTransfer.importRules(from: unknown, folderId: "f").rules.first?.importError?.contains("rule option newPolicy") == true)
    }

    @Test func realHazelNegatedDateConditionsDoNotMatchNewFiles() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")
        let directory = TempDir()
        let file = directory.file("new.txt")
        for (name, expected) in [("No Longer New Files", "2 day"), ("Old Files", "1 week")] {
            let rule = try #require(result.rules.first { $0.name == name })
            let condition = try #require(rule.conditions.first)
            let group = try #require(ConditionGroup.decode(condition.value))
            #expect(condition.kind == .conditionGroup)
            #expect(group.match == .none && group.target == .current && group.conditions.count == 1)
            #expect(group.conditions.first?.kind == .dateAdded)
            #expect(group.conditions.first?.operator == .hazelWithinLast)
            #expect(group.conditions.first?.value == expected)
            #expect(!ConditionEvaluator.evaluate(condition, path: file))
            #expect(!rule.enabled)
        }
        var trashRule = try #require(result.rules.first { $0.name == "Old Files" })
        #expect(trashRule.actions.map(\.kind) == [.moveToTrash])
        trashRule.enabled = true
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [trashRule]) == nil)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [trashRule], batchId: "date").history.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func realHazelNameExclusionsPreserveCaseInsensitiveMatching() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("tmp.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")
        var rule = try #require(result.rules.first { $0.name == "Delete old files" })
        let exclusions = rule.conditions.filter { $0.kind == .nameInsensitive }
        #expect(exclusions.count == 2)
        #expect(exclusions.map(\.operator) == [.isNot, .isNot])
        let directory = TempDir()
        let excluded = directory.file("FILEservers.txt")
        let included = directory.file("report.txt")
        #expect(exclusions.contains { !ConditionEvaluator.evaluate($0, path: excluded) })
        #expect(exclusions.allSatisfy { ConditionEvaluator.evaluate($0, path: included) })
        #expect(!rule.enabled)
        // Exercise the imported name exclusions independently of the other conditions.
        rule.enabled = true
        rule.conditions = exclusions
        rule.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Reviewed"])]), ruleId: rule.id)]
        #expect(RuleEngine.previewFile(path: excluded, depth: 0, rules: [rule]) == nil)
        #expect(RuleEngine.previewFile(path: included, depth: 0, rules: [rule]) != nil)
        #expect(RuleEngine.run(path: included, depth: 0, rules: [rule], batchId: "name").history.first?.status == .applied)
        let watched = directory.file("other.txt")
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        rule.folderId = folder.id
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(FinderTags.read(watched).contains("Reviewed"))
    }

    @Test func realHazelNameContainsMatchesCaseInsensitively() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")
        let rule = try #require(result.rules.first { $0.name == "Move Statements to Dropbox" })
        let names = rule.conditions.filter { $0.kind == .nameInsensitive }
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.operator == .contains })
        let directory = TempDir()
        let matched = directory.file("discover-statement-2024.pdf")
        let other = directory.file("unrelated.pdf")
        #expect(names.contains { ConditionEvaluator.evaluate($0, path: matched) })
        #expect(!names.contains { ConditionEvaluator.evaluate($0, path: other) })
        #expect(rule.conditions.filter { $0.kind == .contents && $0.operator == .containsInsensitive }.count == 5)
        #expect(result.issues.contains { $0.ruleName == rule.name && $0.message.contains("extract or index") })
    }

    @Test func realHazelStatementContentConditionsRunAcrossExecutionPaths() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads.hazelrules"))
        let source = TempDir()
        let destination = TempDir()
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let imported = try RuleTransfer.importRules(from: data, folderId: folder.id)
        var rule = try #require(imported.rules.first { $0.name == "Move Statements to Dropbox" })
        #expect(rule.importError == nil)
        let contentConditions = rule.conditions.filter { $0.kind == .contents }
        #expect(contentConditions.count == 5)
        rule.enabled = true
        rule.actions[0].params = .object([ActionParam.destination: .string(destination.path)])
        try db.insertRule(rule)
        let watcher = WatcherCoordinator(db: db)
        for (index, condition) in contentConditions.enumerated() {
            let preview = source.file("preview-\(index).txt", contents: "Account: \(condition.value)")
            let manual = source.file("manual-\(index).txt", contents: "Account: \(condition.value)")
            let automatic = source.file("watcher-\(index).txt", contents: "Account: \(condition.value)")
            #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun)
            #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "contents").history.first?.status == .applied)
            watcher.handle(path: automatic)
            #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("manual-\(index).txt")))
            #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("watcher-\(index).txt")))
        }
        let nonmatch = source.file("unrelated.txt", contents: "nothing to match")
        #expect(RuleEngine.previewFile(path: nonmatch, depth: 0, rules: [rule]) == nil)
        #expect(try db.listHistory().count == 5)
    }

    @Test func bjangoCapturedFilenamePatternMatches() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_BJANGO"] else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent("Hazel Rules/Move into subfolders if # exists.hazelrules")
        let result = try RuleTransfer.importRules(from: Data(contentsOf: url), folderId: "folder")
        let rule = try #require(result.rules.first)
        let condition = try #require(rule.conditions.first)
        #expect(condition.kind == .customTextMatch)
        #expect(condition.operator == .is)
        #expect(rule.importError == nil)
        #expect(rule.actions.map(\.kind) == [.moveToFolder, .rename])
        let directory = TempDir()
        for name in ["foo#bar.txt", "#bar.txt", "foo#.txt", "#.txt", "#", "foo#bar#baz.txt", "foo\n#bar.txt"] {
            let file = directory.file(name)
            #expect(ConditionEvaluator.evaluate(condition, path: file), "\(name)")
        }
        let file = directory.file("foobar.txt")
        #expect(!ConditionEvaluator.evaluate(condition, path: file))
    }

    @Test func repeatedHazelCapturesWorkInAllAndAlternativeModes() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_BJANGO"] else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent("Hazel Rules/Move into subfolders if # exists.hazelrules")
        let data = try Data(contentsOf: url)
        let original = try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        for mode in [1, 2] {
            var plist = original
            var objects = try #require(plist["$objects"] as? [Any])
            var ruleObject = try #require(objects[3] as? [String: Any]); ruleObject["predicateType"] = mode; objects[3] = ruleObject
            var criteria = try #require(objects[6] as? [String: Any])
            var predicates = try #require(criteria["NS.objects"] as? [Any]); predicates.append(try #require(predicates.first))
            criteria["NS.objects"] = predicates; objects[6] = criteria; plist["$objects"] = objects
            let mutated = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            var rule = try #require(RuleTransfer.importRules(from: mutated, folderId: "folder").rules.first)
            #expect(rule.importError == nil, "\(rule.importError ?? "")")
            #expect(rule.conditions.map(\.kind) == [.customTextMatch, .customTextMatch])
            rule.enabled = true
            let dir = TempDir(); let path = dir.file("folder#item.txt")
            let result = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "captures")
            #expect(result.history.allSatisfy { $0.status == .applied })
            #expect(FileManager.default.fileExists(atPath: "\(dir.path)/folder/item.txt"))
        }
    }

    @Test func importedDateConditionMatchesInPreviewManualRunAndWatcher() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads.hazelrules"))
        let directory = TempDir()
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first {
            $0.name == "Newly Added Files"
        })
        // Use a local tag action to test the date condition independently.
        rule.enabled = true
        rule.actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Reviewed"])]), ruleId: rule.id)]
        let previewFile = directory.file("preview.txt")
        let manualFile = directory.file("manual.txt")
        let watcherFile = directory.file("watcher.txt")
        #expect(RuleEngine.previewFile(path: previewFile, depth: 0, rules: [rule])?.rules.first?.actions.first?.status == .wouldRun)
        #expect(FinderTags.read(previewFile).isEmpty)
        #expect(RuleEngine.run(path: manualFile, depth: 0, rules: [rule], batchId: "date").history.first?.status == .applied)
        #expect(FinderTags.read(manualFile).contains("Reviewed"))
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watcherFile)
        #expect(FinderTags.read(watcherFile).contains("Reviewed"))
        #expect(try db.listHistory().first?.status == .applied)
    }

    @Test func realHazelScreenshotTrashRuleImportsAllConditions() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS_2"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Desktop.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")
        let rule = try #require(result.rules.first { $0.name == "Delete screenshots" })
        #expect(!rule.enabled)
        #expect(rule.actions.map(\.kind) == [.moveToTrash])
        #expect(rule.importError == nil)
        #expect(rule.conditions.contains { $0.kind == .extensionInsensitive && $0.operator == .is && $0.value == "png" })
        let directory = TempDir()
        let file = directory.file("Screen Shot.png", contents: "image")
        let plan = try ActionExecutor.plan(rule.actions[0], path: file)
        #expect(plan.status == .wouldRun)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func realHazelCalendarPredicatesAreImported() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"],
              let secondRoot = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS_2"] else { return }
        let temp = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("tmp.hazelrules"))
        let imported = try RuleTransfer.importRules(from: temp, folderId: "folder")
        let delete = try #require(imported.rules.first { $0.name == "Delete old files" })
        let color = try #require(imported.rules.first { $0.name == "Color_to_be_deleted" })
        #expect(delete.conditions.contains { $0.kind == .dateAdded && $0.operator == .notThisMonth })
        #expect(color.conditions.contains { $0.kind == .dateAdded && $0.operator == .notThisWeek })

        let oldDesktop = try Data(contentsOf: URL(fileURLWithPath: secondRoot).appendingPathComponent("OldDekstop.hazelrules"))
        let oldRule = try #require(RuleTransfer.importRules(from: oldDesktop, folderId: "folder").rules.first)
        #expect(oldRule.conditions.contains { $0.kind == .dateAdded && $0.operator == .beforeThisWeek })
    }

    @Test func realHazelRuleSurvivesPersistenceAndRunsFromWatcher() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads.hazelrules"))
        let directory = TempDir()
        let targetDirectory = TempDir()
        let file = directory.file("invoice.PDF", contents: "document")
        let folder = WatchedFolder(path: directory.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first {
            $0.name == "Downloaded Documents to Dropbox"
        })
        rule.enabled = true
        rule.actions[0].params = .object([ActionParam.destination: .string(targetDirectory.path), ActionParam.discardDuplicates: .bool(true)])
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file)

        let history = try db.listHistory()
        #expect(history.count == 1)
        #expect(history[0].status == .applied)
        #expect(FileManager.default.fileExists(atPath: (targetDirectory.path as NSString).appendingPathComponent("invoice.PDF")))
    }

    @Test func secondRealHazelMoveWorksAfterDestinationReview() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS_2"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Desktop.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")
        let rule = try #require(result.rules.first { $0.name == "Move old files" })
        #expect(!rule.enabled)
        #expect(rule.actions.map(\.kind) == [.moveToFolder])
        #expect(rule.actions[0].params[ActionParam.destination]?.stringValue?.hasSuffix("/OldDekstop") == true)
        #expect(rule.conditions.contains { $0.kind == .dateAdded && $0.operator == .beforeToday })
        #expect(rule.conditions.contains { $0.kind == .dateLastOpened && $0.operator == .beforeToday })
        #expect(rule.importError == nil)
        let directory = TempDir()
        let target = TempDir()
        let file = directory.file("example.txt", contents: "hello")
        var action = rule.actions[0]
        action.params = .object([ActionParam.destination: .string(target.path)])
        let plan = try ActionExecutor.plan(action, path: file)
        #expect(plan.status == .wouldRun)
        _ = try ActionExecutor.execute(action, path: file)
        #expect(try String(contentsOfFile: (target.path as NSString).appendingPathComponent("example.txt"), encoding: .utf8) == "hello")
    }

    @Test func realHazelNameAndExtensionRenamePatternWorks() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Statements.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "folder")
        let rule = try #require(result.rules.first { $0.name == "File Citi Statement" })
        #expect(!rule.enabled)
        let action = try #require(rule.actions.first { $0.kind == .rename })
        #expect(action.params["hazel_pattern_tokens"] == .array([
            .object(["type": .string("literal"), "value": .string("CITI_")]),
            .object(["type": .string("name")]), .object(["type": .string("extension")])
        ]))
        let directory = TempDir()
        let file = directory.file("statement.PDF", contents: "document")
        let plan = try ActionExecutor.plan(action, path: file)
        #expect(plan.description == "Rename to CITI_statement.PDF")
        let applied = try ActionExecutor.execute(action, path: file)
        #expect((applied.newPath as NSString).lastPathComponent == "CITI_statement.PDF")
        #expect(try String(contentsOfFile: applied.newPath, encoding: .utf8) == "document")
        let noExtension = directory.file("receipt", contents: "receipt")
        let second = try ActionExecutor.execute(action, path: noExtension)
        #expect((second.newPath as NSString).lastPathComponent == "CITI_receipt")
        #expect(rule.actions.contains { $0.kind == .runHazelAppleScript })
        #expect(result.issues.contains { $0.ruleName == rule.name && $0.message.contains("Review the imported AppleScript") })
    }

    @Test func bjangoImageRenameAndMoveActionsWorkAfterReview() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_BJANGO"] else { return }
        for scale in [2, 3] {
            let fileURL = URL(fileURLWithPath: root).appendingPathComponent("Hazel Rules/Auto @\(scale)x, then move.hazelrules")
            let result = try RuleTransfer.importRules(from: Data(contentsOf: fileURL), folderId: "folder")
            var rule = try #require(result.rules.first)
            #expect(!rule.enabled)
            #expect(rule.actions.map(\.kind) == [.rename, .moveToFolder])
            #expect(rule.actions[0].params["hazel_pattern_tokens"] == .array([
                .object(["type": .string("name")]),
                .object(["type": .string("literal"), "value": .string("@\(scale)x")]),
                .object(["type": .string("extension")])
            ]))
            #expect(rule.conditions.map(\.kind) == [.contentType])
            #expect(rule.conditions.first?.value == "public.image")

            // Use a temporary destination for this test.
            let directory = TempDir()
            let target = TempDir()
            let file = directory.file("icon.png", contents: "test")
            rule.enabled = true
            rule.actions[1].params = .object([ActionParam.destination: .string(target.path)])
            let notImage = directory.file("notes.txt", contents: "text")
            #expect(RuleEngine.previewFile(path: notImage, depth: 0, rules: [rule]) == nil)
            let preview = try #require(RuleEngine.previewFile(path: file, depth: 0, rules: [rule]))
            #expect(preview.rules[0].actions.map(\.status) == [.wouldRun, .wouldRun])
            let run = RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "bjango")
            #expect(run.history.map(\.status) == [.applied, .applied])
            let destination = (target.path as NSString).appendingPathComponent("icon@\(scale)x.png")
            #expect(try String(contentsOfFile: destination, encoding: .utf8) == "test")

            let watched = directory.file("watch.png", contents: "watch")
            let db = try Database(path: ":memory:")
            let folder = WatchedFolder(path: directory.path)
            try db.insertFolder(folder)
            rule.folderId = folder.id
            try db.insertRule(rule)
            WatcherCoordinator(db: db).handle(path: watched)
            let watchedDestination = (target.path as NSString).appendingPathComponent("watch@\(scale)x.png")
            #expect(try String(contentsOfFile: watchedDestination, encoding: .utf8) == "watch")
            #expect(try db.listHistory().filter { $0.status == .applied }.count == 2)
        }
    }

    @Test func cyclicHazelArchivesAreRejected() throws {
        let fixture: [String: Any] = [
            "$archiver": "NSKeyedArchiver",
            "$top": ["root": ["CF$UID": 1]],
            "$objects": ["$null", ["$class": ["CF$UID": 2], "rules": ["CF$UID": 1]], ["$classname": "HazelRuleSet"]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)

        #expect(throws: RuleTransferError.self) {
            try RuleTransfer.importRules(from: data, folderId: "folder")
        }
    }

    @Test func importedActionsPreservePositionsEvenWhenArrayIsUnsorted() throws {
        let source = Rule(folderId: "source", name: "Ordered", actions: [
            Action(ruleId: "source", kind: .moveToTrash, params: .object([:]), position: 20),
            Action(ruleId: "source", kind: .rename, params: .object([ActionParam.pattern: .string("new-{name}")]), position: 10)
        ])
        let imported = try #require(RuleTransfer.importRules(from: RuleTransfer.exportForel([source]), folderId: "destination").rules.first)
        #expect(imported.actions.sorted { $0.position < $1.position }.map(\.kind) == [.rename, .moveToTrash])
        #expect(imported.actions.map(\.position) == [20, 10])
    }

    @Test func importedBatchesEnforceFreePlanAndRollbackAtomically() throws {
        let dir = TempDir(); let db = try Database(path: ":memory:")
        let folders = (0..<3).map { WatchedFolder(path: dir.dir("folder\($0)")) }
        for folder in folders { try db.insertFolder(folder) }
        let normal = makeRule(folderId: folders[1].id, name: "Normal")
        var premium = makeRule(folderId: folders[1].id, name: "Premium")
        premium.actions = [makeAction(.importToLibrary, .object([ActionParam.libraryType: .string("photos")]), ruleId: premium.id)]
        #expect(throws: FreePlanError.feature(.libraryImports)) { try db.importRules([normal, premium], toFolderID: folders[1].id, isPro: false) }
        #expect(try db.listRules(folderId: folders[1].id).isEmpty)
        var outside = normal; outside.folderId = folders[2].id
        #expect(throws: FreePlanError.proFolder) { try db.importRules([outside], toFolderID: folders[2].id, isPro: false) }
        #expect(try db.listRules(folderId: folders[2].id).isEmpty)
        var duplicate = normal; duplicate.name = "Duplicate ID"
        #expect(throws: SQLiteError.self) { try db.importRules([normal, duplicate], toFolderID: folders[1].id, isPro: true) }
        #expect(try db.listRules(folderId: folders[1].id).isEmpty)
        try db.importRules([normal, premium], toFolderID: folders[1].id, isPro: true)
        #expect(try db.listRules(folderId: folders[1].id).map(\.name) == ["Normal", "Premium"])
    }

    @Test func importLimitsRejectOversizedAndDeepInputsBeforeDecoding() throws {
        let dir = TempDir(); let path = dir.file("oversized.forelrules")
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try file.truncate(atOffset: UInt64(RuleTransfer.maximumFileSize + 1)); try file.close()
        #expect(throws: RuleTransferError.invalidNativeFile) { try RuleTransfer.readFile(at: URL(fileURLWithPath: path)) }
        let deep = Data((String(repeating: "[", count: 65) + String(repeating: "]", count: 65)).utf8)
        #expect(throws: RuleTransferError.invalidNativeFile) { try RuleTransfer.importRules(from: deep, folderId: "f") }
        let tooMany = Data(("[" + Array(repeating: "0", count: 100_001).joined(separator: ",") + "]").utf8)
        #expect(throws: RuleTransferError.invalidNativeFile) { try RuleTransfer.importRules(from: tooMany, folderId: "f") }
    }

    @Test func unsupportedNativeVersionsAreRejected() throws {
        let data = Data(#"{"format":"forel-rules","version":999,"rules":[]}"#.utf8)

        #expect(throws: RuleTransferError.self) {
            try RuleTransfer.importRules(from: data, folderId: "folder")
        }
    }

    private func hazelFixture() -> [String: Any] {
        let uid: (Int) -> [String: Any] = { ["CF$UID": $0] }
        return [
            "$archiver": "NSKeyedArchiver",
            "$top": ["root": uid(1)],
            "$objects": [
                "$null",
                ["$class": uid(2), "rules": uid(3)],
                ["$classname": "HazelRuleSet"],
                ["$class": uid(4), "NS.objects": [uid(5), uid(11)]],
                ["$classname": "NSArray"],
                [
                    "$class": uid(6), "description": "Archive G-code", "predicateType": 1,
                    "criteria": uid(7), "actions": uid(9),
                ],
                ["$classname": "HazelRule"],
                ["$class": uid(4), "NS.objects": [uid(8)]],
                [
                    "NSLeftExpression": ["NSKeyPath": "displayExtension"],
                    "NSRightExpression": ["NSConstantValue": ".gcode"],
                    "NSPredicateOperator": ["NSOperatorType": 4, "NSModifier": 0],
                ],
                ["$class": uid(4), "NS.objects": [uid(10)]],
                ["$class": uid(16)],
                [
                    "$class": uid(12), "description": "Needs review", "predicateType": 1,
                    "criteria": uid(7), "actions": uid(13),
                ],
                ["$classname": "HazelRule"],
                ["$class": uid(4), "NS.objects": [uid(14)]],
                ["$class": uid(15)],
                ["$classname": "HazelUnsupportedAction"],
                ["$classname": "HazelTrashAction"],
            ],
        ]
    }
}
