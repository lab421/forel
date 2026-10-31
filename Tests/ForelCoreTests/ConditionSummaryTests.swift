import Foundation
import Testing
@testable import ForelCore

@Suite struct ConditionSummaryTests {
    @Test func typedValuesAreReadableAndDoNotExposeSecrets() throws {
        let id = UUID().uuidString
        let password = PasswordContentCondition(credentialID: id, operand: "invoice")
        let condition = makeCondition(.contentsWithPassword, .contains, password.encoded)
        #expect(condition.displayValue == "PDF text: invoice")
        #expect(!condition.displayValue.contains(id))
        let script = HazelScriptCondition(source: "secret-source")
        #expect(!makeCondition(.hazelScriptCondition, .is, script.encoded).displayValue.contains("secret-source"))
        let schedule = CurrentTimeCondition.Schedule(time: "09:15", weekdays: "2,3")
        #expect(makeCondition(.currentTime, .is, schedule.encoded).displayValue == "09:15, weekdays 2,3")
        let dir = TempDir(); let path = dir.file("item.pdf")
        let rule = makeRule(name: "PDF", conditionMatch: .any, conditions: [condition, makeCondition(.anyFile, .is, "")], actions: [makeAction(.ignore, .object([:]))])
        let preview = try #require(RuleEngine.previewFile(path: path, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.conditions.first?.value == "PDF text: invoice")
    }
}
