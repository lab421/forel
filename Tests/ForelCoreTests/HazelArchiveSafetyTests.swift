import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelArchiveSafetyTests {
    private func archive(_ objects: [Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "$archiver": "NSKeyedArchiver", "$version": 100000,
            "$top": ["root": ["CF$UID": 1]], "$objects": objects
        ], format: .xml, options: 0)
    }

    @Test func cyclesAndInvalidReferencesAreRejected() throws {
        for bad in [["CF$UID": 1], ["CF$UID": 999], ["CF$UID": -1]] {
            let data = try archive(["$null", ["rules": ["NS.objects": [bad]]]])
            #expect(throws: RuleTransferError.self) { try RuleTransfer.importRules(from: data, folderId: "f") }
        }
    }

    @Test func repeatedReferencesHaveBoundedExpansion() throws {
        var objects: [Any] = ["$null", ["rules": ["CF$UID": 2]]]
        for index in 2..<14 {
            objects.append(["NS.objects": Array(repeating: ["CF$UID": index + 1], count: 4)])
        }
        objects.append("leaf")
        let data = try archive(objects)
        #expect(data.count < 20_000)
        #expect(throws: RuleTransferError.self) { try RuleTransfer.importRules(from: data, folderId: "f") }
    }

    @Test func hugeDateFieldDigitsCannotOverflow() throws {
        func uid(_ n: Int) -> [String: Int] { ["CF$UID": n] }
        let objects: [Any] = [
            "$null",
            ["rules": uid(2)],
            ["NS.objects": [uid(3)]],
            ["$class": uid(4), "description": "bad date", "predicateType": 1,
             "criteria": uid(5), "actions": uid(6)],
            ["$classname": "HazelRule"],
            ["NS.objects": []],
            ["NS.objects": [uid(7)]],
            ["$class": uid(8), "parameter": uid(9)],
            ["$classname": "HazelRenameAction"],
            ["NS.objects": [uid(10)]],
            ["$class": uid(11), "name": "dateAdded", "case": 0,
             "alternateFormatIndex": 0, "integerDigits": 0, "listSelection": -2, "subTokens": uid(12)],
            ["$classname": "HazelFilenameFormatToken"],
            ["NS.objects": [uid(13)]],
            ["$class": uid(14), "name": "year", "digitCount": 1e100, "alternateFormatIndex": 0],
            ["$classname": "HazelDateFormatToken"]
        ]
        let result = try RuleTransfer.importRules(from: archive(objects), folderId: "f")
        #expect(result.rules.first?.importError != nil)
    }
}
