import Foundation
import Testing
@testable import ForelCore

@Suite struct RuleTransferNativeLimitTests {
    private func expectInvalid(_ data: Data) {
        do {
            _ = try RuleTransfer.importRules(from: data, folderId: "folder")
            Issue.record("Expected an invalid native export error")
        } catch let error as RuleTransferError {
            if case .invalidNativeFile = error {} else { Issue.record("Wrong import error: \(error)") }
        } catch { Issue.record("Wrong import error: \(error)") }
    }

    @Test func rejectsOversizedNativeJSONBeforeDecoding() {
        var data = Data("{\"format\":\"forel-rules\",\"padding\":\"".utf8)
        data.append(Data(repeating: 65, count: 20 * 1024 * 1024))
        data.append(Data("\"}".utf8))
        expectInvalid(data)
    }

    @Test func rejectsDeepNativeJSONBeforeDecoding() {
        let nested = String(repeating: "[", count: 1000) + "0" + String(repeating: "]", count: 1000)
        expectInvalid(Data("{\"format\":\"forel-rules\",\"rules\":[{\"actions\":[{\"params\":\(nested)}]}]}".utf8))
    }

    @Test func rejectsExcessiveNodeCount() {
        let values = Array(repeating: "0", count: 100_001).joined(separator: ",")
        expectInvalid(Data("{\"format\":\"forel-rules\",\"rules\":[\(values)]}".utf8))
    }

    @Test func bracketsAndEscapesInsideStringsDoNotCountAsNesting() throws {
        var rule = makeRule(name: String(repeating: "[\\\"{", count: 100))
        rule.actions = [makeAction(.ignore, .object([:]), ruleId: rule.id)]
        let encoded = try RuleTransfer.exportForel([rule])
        let imported = try RuleTransfer.importRules(from: encoded, folderId: "folder")
        #expect(imported.rules.first?.name == rule.name)
    }
}
