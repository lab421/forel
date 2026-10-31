import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelPatternTests {
    private func action(_ tokens: [JSONValue], sort: Bool = false) -> Action {
        Action(ruleId: "r", kind: sort ? .moveToFolder : .rename, params: .object([
            ActionParam.pattern: .string("Hazel pattern"), ActionParam.destination: .string("."),
            HazelPattern.sortKey: .bool(sort), HazelPattern.tokensKey: .array(tokens),
            HazelPattern.regexKey: .string("(?i)^(.*?)#(.*?)$"),
            HazelPattern.namesKey: .stringArray(["folder", "asset"])
        ]), position: 0)
    }

    private func capture(_ name: String) -> JSONValue {
        .object(["type": .string("capture"), "value": .string(name)])
    }

    @Test func capturedValuesRemainStableAcrossMoves() throws {
        let dir = TempDir()
        let path = dir.file("projects#photo.jpg")
        let sort = action([capture("folder")], sort: true)
        let rename = action([capture("asset"), .object(["type": .string("extension")])])
        let plan = try ActionExecutor.plan(sort, path: path, contextPath: path)
        let afterSort = try #require(plan.targetPath)
        let renamePlan = try ActionExecutor.plan(rename, path: afterSort, contextPath: path)
        #expect(renamePlan.targetPath == "\(dir.path)/projects/photo.jpg")
        let moved = try ActionExecutor.execute(sort, path: path, contextPath: path)
        let renamed = try ActionExecutor.execute(rename, path: moved.newPath, contextPath: path)
        #expect(renamed.newPath == renamePlan.targetPath)
        #expect(FileManager.default.fileExists(atPath: renamed.newPath))
    }

    @Test func tokenCaseTransformsApplyBeforeConcatenation() throws {
        let dir = TempDir()
        let path = dir.file("folder#item.txt")
        let pattern = action([
            .object(["type": .string("literal"), "value": .string("MiXeD TéXT"), "case": .string("title")]),
            .object(["type": .string("literal"), "value": .string(" MiXeD TéXT"), "case": .string("lower")]),
            .object(["type": .string("literal"), "value": .string(" MiXeD TéXT"), "case": .string("upper")])
        ])
        #expect(try HazelPattern.render(pattern, path: path, contextPath: path) == "Mixed Téxt mixed téxt MIXED TÉXT")
    }

    @Test func scriptListTokensSelectItemsAndFailClosed() throws {
        let dir = TempDir()
        let path = dir.file("folder#item.txt")
        var context = HazelPatternContext(path: path)
        context.attributes["People"] = .array([.string("Ada"), .string("Grace")])
        func token(_ selection: String) -> JSONValue {
            .object(["type": .string("attributeList"), "value": .string("People"),
                     "selection": .string(selection), "separator": .string(" + ")])
        }
        #expect(try HazelPattern.render(action([token("all")]), path: path, contextPath: path, context: context) == "Ada + Grace")
        #expect(try HazelPattern.render(action([token("first")]), path: path, contextPath: path, context: context) == "Ada")
        #expect(try HazelPattern.render(action([token("last")]), path: path, contextPath: path, context: context) == "Grace")
        let indexed: JSONValue = .object(["type": .string("attributeList"), "value": .string("People"), "selection": .string("index"), "index": .string("-2")])
        #expect(try HazelPattern.render(action([indexed]), path: path, contextPath: path, context: context) == "Ada")
        context.attributes["People"] = .array([.number(2)])
        #expect(throws: ActionError.self) { try HazelPattern.render(action([token("all")]), path: path, contextPath: path, context: context) }
        context.attributes["People"] = .array([])
        #expect(throws: ActionError.self) { try HazelPattern.render(action([token("first")]), path: path, contextPath: path, context: context) }
    }

    @Test func scriptNumberTokenAdjustsAndRejectsInvalidValues() throws {
        let dir = TempDir()
        let path = dir.file("folder#item.txt")
        let token: JSONValue = .object(["type": .string("attributeNumber"), "value": .string("Amount"), "adjustment": .string("-0.25")])
        let pattern = action([token])
        var context = HazelPatternContext(path: path)
        context.attributes["Amount"] = .number(2.5)
        #expect(try HazelPattern.render(pattern, path: path, contextPath: path, context: context) == "2.25")
        context.attributes["Amount"] = .string("2.5")
        #expect(throws: ActionError.self) { try HazelPattern.render(pattern, path: path, contextPath: path, context: context) }
        #expect(HazelPattern.validationError(action([.object(["type": .string("attributeNumber"), "value": .string("Amount"), "adjustment": .string("NaN")])])) != nil)
    }
    @Test func alphabeticCounterContinuesAfterZ() throws {
        let dir = TempDir(); let path = dir.file("folder#item.txt")
        var context = HazelPatternContext(path: path)
        let token: JSONValue = .object(["type": .string("counter"), "digits": .string("0"), "numberFormat": .string("lowercase")])
        for (number, expected) in [(1, "a"), (26, "z"), (27, "aa"), (52, "az"), (53, "ba")] {
            context.counterValue = Int64(number)
            #expect(try HazelPattern.render(action([token]), path: path, contextPath: path, context: context) == expected)
        }
    }
    @Test func tokenTransformsApplyInOrderAndUseMissingDefault() throws {
        let dir = TempDir(); let path = dir.file("folder#item.txt")
        let token: JSONValue = .object([
            "type": .string("attribute"), "value": .string("Absent"), "defaultValue": .string("café-123"),
            "replacements": .array([
                .object(["find": .string("café"), "replace": .string("茶🍵"), "regex": .bool(false)]),
                .object(["find": .string("[0-9]+"), "replace": .string("OK"), "regex": .bool(true)])
            ]), "maxLength": .string("4")
        ])
        #expect(try HazelPattern.render(action([token]), path: path, contextPath: path) == "茶🍵-O")
        let invalid: JSONValue = .object(["type": .string("literal"), "value": .string("x"), "replacements": .array([
            .object(["find": .string("["), "replace": .string(""), "regex": .bool(true)])
        ])])
        #expect(HazelPattern.validationError(action([invalid])) != nil)
        let expansion: JSONValue = .object(["type": .string("literal"), "value": .string("ß"), "case": .string("upper"), "maxLength": .string("1")])
        #expect(try HazelPattern.render(action([expansion]), path: path, contextPath: path) == "S")
        let bomb: JSONValue = .object(["type": .string("literal"), "value": .string(String(repeating: "x", count: 3000)), "replacements": .array([
            .object(["find": .string("(x+)"), "replace": .string(String(repeating: "$1", count: 500)), "regex": .bool(true)])
        ])])
        #expect(throws: ActionError.self) { try HazelPattern.render(action([bomb]), path: path, contextPath: path) }
        let number: JSONValue = .object(["type": .string("literal"), "value": .string("-1234.5"), "numericAdjustment": .string("-0.5"), "minimumDigits": .string("6"), "groupingSeparator": .string(",")])
        #expect(try HazelPattern.render(action([number]), path: path, contextPath: path) == "-001,235")
    }
    @Test func splitAttributeCreatesSafeNestedFolders() throws {
        let dir = TempDir(); let path = dir.file("folder#item.txt")
        var context = HazelPatternContext(path: path); context.attributes["Path"] = .string("one/two")
        let token: JSONValue = .object(["type": .string("attribute"), "value": .string("Path"), "pathSplit": .string("/")])
        let pattern = action([.object(["type": .string("literal"), "value": .string("prefix-")]), token], sort: true)
        #expect(try HazelPattern.sortDestination(pattern, path: path, contextPath: path, context: context) == "\(dir.path)/prefix-one/two")
        context.attributes["Path"] = .string("one/../outside")
        #expect(throws: ActionError.self) { try HazelPattern.sortDestination(pattern, path: path, contextPath: path, context: context) }
        context.attributes["Path"] = .string("/absolute")
        #expect(throws: ActionError.self) { try HazelPattern.sortDestination(pattern, path: path, contextPath: path, context: context) }
    }
    @Test func spotlightTokenFreezesTypedMetadataBeforeMove() throws {
        let dir = TempDir(); let path = dir.file("folder#item.txt")
        let token: JSONValue = .object(["type": .string("spotlight"), "source": .string("kMDItemAuthors"), "valueType": .string("list"), "selection": .string("index"), "index": .string("-1")])
        let pattern = action([token])
        var reads = 0
        let context = HazelPatternContext(path: path, actions: [pattern], spotlightReader: { key, readPath in
            reads += 1; #expect(key == "kMDItemAuthors" && readPath == path)
            return .array([.string("Ada"), .string("Grace")])
        })
        let moved = "\(dir.path)/renamed.txt"; try FileManager.default.moveItem(atPath: path, toPath: moved)
        #expect(try HazelPattern.render(pattern, path: moved, contextPath: path, context: context) == "Grace")
        #expect(reads == 1)
        let unavailable = HazelPatternContext(path: moved, actions: [pattern], spotlightReader: { _, _ in nil })
        #expect(throws: ActionError.self) { try HazelPattern.render(pattern, path: moved, contextPath: path, context: unavailable) }
    }

    @Test func scriptDateTokenAppliesCalendarAdjustment() throws {
        let dir = TempDir()
        let path = dir.file("folder#item.txt")
        var context = HazelPatternContext(path: path)
        let baseline = try #require(ISO8601DateFormatter().date(from: "2026-03-15T12:00:00Z"))
        context.attributes["Date"] = .object(["__forelDate": .number(baseline.timeIntervalSince1970)])
        let token: JSONValue = .object(["type": .string("attributeDate"), "source": .string("Date"), "value": .string("yyyy-MM-dd"), "adjustDays": .string("2")])
        let expectedDate = try #require(Calendar.current.date(byAdding: .day, value: 2, to: baseline))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        #expect(try HazelPattern.render(action([token]), path: path, contextPath: path, context: context) == formatter.string(from: expectedDate))
    }

    @Test func unknownCustomAttributeDeclarationBlocksImport() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_PHOTOS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("google_photos.hazelrules"))
        var plist = try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        var objects = try #require(plist["$objects"] as? [Any])
        // Pinned public export: object 65 is its script-date declaration.
        let index = 65
        #expect(objects.indices.contains(index))
        var item = try #require(objects[index] as? [String: Any])
        item["unrecognizedSetting"] = true
        objects[index] = item
        plist["$objects"] = objects
        let mutated = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let imported = try RuleTransfer.importRules(from: mutated, folderId: "f")
        #expect(imported.rules.contains { $0.importError?.contains("custom attribute declaration") == true })
    }

    @Test func rejectsMissingAndUnsafeValues() throws {
        let dir = TempDir()
        let path = dir.file("..#photo.jpg")
        #expect(throws: ActionError.self) { try ActionExecutor.plan(action([capture("folder")], sort: true), path: path) }
        #expect(throws: ActionError.self) { try ActionExecutor.plan(action([capture("absent")]), path: path) }
        #expect(throws: ActionError.self) {
            try ActionExecutor.plan(action([.object(["type": .string("literal"), "value": .string("../outside")])], sort: true), path: path)
        }
        let outside = TempDir()
        try FileManager.default.createSymbolicLink(atPath: "\(dir.path)/link", withDestinationPath: outside.path)
        #expect(throws: ActionError.self) {
            try ActionExecutor.plan(action([.object(["type": .string("literal"), "value": .string("link")])], sort: true), path: path)
        }
        try FileManager.default.createDirectory(atPath: "\(dir.path)/safe", withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: "\(dir.path)/safe/link", withDestinationPath: outside.path)
        let nested = action([
            .object(["type": .string("literal"), "value": .string("safe")]),
            .object(["type": .string("pathSeparator")]),
            .object(["type": .string("literal"), "value": .string("link")])
        ], sort: true)
        #expect(throws: ActionError.self) { try ActionExecutor.plan(nested, path: path) }
    }

    @Test func dateRequiresMetadataAndMoveConflictPreservesBoth() throws {
        let dir = TempDir()
        let path = dir.file("folder#photo.jpg")
        let taken: JSONValue = .object(["type": .string("date"), "source": .string("hazelbuiltin:dateTaken"), "value": .string("yyyy-MM-dd")])
        #expect(throws: ActionError.self) { try ActionExecutor.plan(action([taken]), path: path) }
        try FileManager.default.createDirectory(atPath: "\(dir.path)/folder", withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: URL(fileURLWithPath: "\(dir.path)/folder/folder#photo.jpg"))
        let sort = action([capture("folder")], sort: true)
        let plan = try ActionExecutor.plan(sort, path: path)
        let applied = try ActionExecutor.execute(sort, path: path)
        #expect(plan.targetPath == applied.newPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: "\(dir.path)/folder/folder#photo.jpg")) == Data("existing".utf8))
    }

    @Test func metadataIsFrozenBeforeMove() throws {
        let dir = TempDir()
        let path = dir.file("folder#photo.jpg")
        let originalDate = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: path)
        let context = HazelPatternContext(path: path)
        let sort = action([capture("folder")], sort: true)
        let moved = try ActionExecutor.execute(sort, path: path, hazelContext: context)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: moved.newPath)
        let date: JSONValue = .object(["type": .string("date"), "source": .string("dateModified"), "value": .string("yyyy-MM-dd")])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let target = try ActionExecutor.plan(action([date]), path: moved.newPath, hazelContext: context).targetPath
        #expect(target == "\(dir.path)/folder/\(formatter.string(from: originalDate))")
    }

    @Test func bjangoExportRunsInPreviewManualAndWatcher() throws {
        guard let corpus = ProcessInfo.processInfo.environment["FOREL_HAZEL_BJANGO"] else { return }
        let url = URL(fileURLWithPath: corpus).appendingPathComponent("Hazel Rules/Move into subfolders if # exists.hazelrules")
        let dir = TempDir()
        let folder = WatchedFolder(path: dir.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let imported = try RuleTransfer.importRules(from: Data(contentsOf: url), folderId: folder.id)
        var rule = try #require(imported.rules.first)
        #expect(rule.importError == nil, "\(rule.importError ?? "")")
        rule.enabled = true
        let preview = dir.file("one#preview.txt")
        let manual = dir.file("two#manual.txt")
        let watched = dir.file("three#watched.txt")
        let result = try #require(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]))
        #expect(result.rules.first?.actions.last?.targetPath == "\(dir.path)/one/preview.txt")
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "patterns").history.allSatisfy { $0.status == .applied })
        #expect(FileManager.default.fileExists(atPath: "\(dir.path)/two/manual.txt"))
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(FileManager.default.fileExists(atPath: "\(dir.path)/three/watched.txt"))
    }

    @Test func kaiserExportUsesOriginalAddedDateAfterMove() throws {
        guard let corpus = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: corpus).appendingPathComponent("Statements.hazelrules"))
        let source = TempDir(), destination = TempDir()
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let imported = try RuleTransfer.importRules(from: data, folderId: folder.id)
        var rule = try #require(imported.rules.first { $0.name.localizedCaseInsensitiveContains("kaiser") })
        #expect(rule.importError == nil, "\(rule.importError ?? "")")
        #expect(rule.actions.map(\.kind) == [.moveToFolder, .rename, .runHazelAppleScript])
        rule.enabled = true
        rule.actions[0].params = .object([ActionParam.destination: .string(destination.path)])
        rule.actions[2].kind = .runScript
        rule.actions[2].params = .object([ActionParam.script: .string("true")])
        func fixture(_ suffix: String) throws -> (String, String) {
            let path = source.file("KaiserPay-\(suffix).pdf")
            let context = HazelPatternContext(path: path, actions: rule.actions)
            let date = try #require(context.dates["dateAdded"])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return (path, "\(destination.path)/Kaiser_\(formatter.string(from: date))_KaiserPay-\(suffix).pdf")
        }
        let (preview, previewTarget) = try fixture("preview")
        let (manual, manualTarget) = try fixture("manual")
        let (watched, watchedTarget) = try fixture("watcher")
        let plan = try #require(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]))
        #expect(plan.rules.first?.actions.dropFirst().first?.targetPath == previewTarget)
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "kaiser").history.allSatisfy { $0.status == .applied })
        #expect(FileManager.default.fileExists(atPath: manualTarget))
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(FileManager.default.fileExists(atPath: watchedTarget))
    }

    @Test func photoExportRendersCounterCaseAndNestedDateFolders() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_PHOTOS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("google_photos.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "f")
        let rule = try #require(result.rules.first { $0.name == "Move images and videos to photos folder" })
        #expect(rule.importError == nil, "\(rule.importError ?? "")")
        let rename = try #require(rule.actions.first { $0.kind == .rename })
        let sort = try #require(rule.actions.first { $0.params[HazelPattern.sortKey]?.boolValue == true })
        #expect(rename.params[HazelPattern.tokensKey]?.arrayValue?.contains { $0["type"]?.stringValue == "counter" && $0["digits"]?.stringValue == "4" } == true)
        #expect(sort.params[HazelPattern.tokensKey]?.arrayValue?.filter { $0["type"]?.stringValue == "pathSeparator" }.count == 2)
        #expect(sort.params[ActionParam.discardDuplicates]?.boolValue == true)
        let directory = TempDir()
        let path = directory.file("image.JPG")
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2024, month: 5, day: 9, hour: 12)))
        var context = HazelPatternContext(path: path)
        context.attributes["hazelcustomtoken:exif_create_date"] = .object(["__forelDate": .number(date.timeIntervalSince1970)])
        context.counterValue = 7
        #expect(try HazelPattern.render(rename, path: path, contextPath: path, context: context) == "2024-05-09 0007.jpg")
        #expect(try HazelPattern.sortDestination(sort, path: path, contextPath: path, context: context) == "\(directory.path)/2024/05-May/May 9, 2024")
    }

    @Test func ticklerWordAndNumberCapturesSurviveMoves() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_TICKLER"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Downloads.hazelrules"))
        let source = TempDir(), destination = TempDir()
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:"); try db.insertFolder(folder)
        var rule = try #require(RuleTransfer.importRules(from: data, folderId: folder.id).rules.first)
        #expect(rule.importError == nil, "\(rule.importError ?? "")")
        #expect(rule.actions.map(\.kind) == [.setFinderLabel, .moveToFolder, .moveToFolder, .moveToFolder, .rename, .setFinderComment])
        rule.enabled = true
        rule.actions[1].params = .object([ActionParam.destination: .string(destination.path)])
        let preview = source.file("preview- tickle May 9.pdf")
        let manual = source.file("manual- tickle May 9.pdf")
        let watched = source.file("watched- tickle May 9.pdf")
        let invalid = source.file("bad- tickle 123 May.pdf")
        let condition = try #require(rule.conditions.first)
        #expect(!ConditionEvaluator.evaluate(condition, path: invalid))
        let plan = try #require(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule]))
        #expect(plan.rules.first?.actions[4].targetPath == "\(destination.path)/May/9/preview.pdf")
        let manualResult = RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "tickler")
        #expect(manualResult.history.allSatisfy { $0.status == .applied || $0.status == .skipped }, "\(manualResult.history.map(\.message))")
        #expect(FileManager.default.fileExists(atPath: "\(destination.path)/May/9/manual.pdf"))
        try db.insertRule(rule)
        WatcherCoordinator(db: db).handle(path: watched)
        #expect(FileManager.default.fileExists(atPath: "\(destination.path)/May/9/watched.pdf"))
    }

    @Test func screenshotExportPreservesAmPmDateFormat() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS_3"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Screen Shots.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: "f")
        let rule = try #require(result.rules.first)
        #expect(rule.importError == nil, "\(rule.importError ?? "")")
        let rename = try #require(rule.actions.first { $0.kind == .rename })
        let dir = TempDir()
        let path = dir.file("screen.PNG")
        let context = HazelPatternContext(path: path, actions: rule.actions)
        let added = try #require(context.dates["dateAdded"])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-hhmmssaa"
        #expect(try HazelPattern.render(rename, path: path, contextPath: path, context: context) == formatter.string(from: added) + ".PNG")
    }
}
