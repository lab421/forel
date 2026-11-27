// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421

import Foundation
import Testing
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
    @Test func unsupportedNativeVersionsAreRejected() throws {
        let data = Data(#"{"format":"forel-rules","version":999,"rules":[]}"#.utf8)
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
}
