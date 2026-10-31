import Foundation
import Testing
@testable import ForelCore

@Suite struct SpotlightConditionTests {
    @Test func customListCollectsMatchesFromContentsAndTags() throws {
        let dir = TempDir(); let path = dir.file("input.txt", contents: "red, green, blue")
        var spec = CustomTextCondition(); spec.names = "Colors"; spec.source = "contents"; spec.pattern = "([a-z]+)"; spec.collectAllMatches = true
        var attrs: [String: JSONValue] = [:]
        #expect(try ConditionEvaluator.evaluateWithContext(makeCondition(.customTextMatch, .is, spec.encoded), path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attrs) == true)
        #expect(attrs["Colors"] == .array([.string("red"), .string("green"), .string("blue")]))
        var context = HazelPatternContext(path: path); context.attributes = attrs
        for (selection, index, expected) in [("first", "1", "red"), ("last", "1", "blue"), ("index", "2", "green")] {
            let token: JSONValue = .object(["type": .string("attributeList"), "value": .string("Colors"), "selection": .string(selection), "index": .string(index)])
            let action = makeAction(.rename, .object([HazelPattern.tokensKey: .array([token])]))
            #expect(try HazelPattern.render(action, path: path, contextPath: path, context: context) == expected)
        }
        try FinderTags.write(path, ["red", "blue"])
        spec.source = "tags"; attrs = [:]
        #expect(try ConditionEvaluator.evaluateWithContext(makeCondition(.customTextMatch, .is, spec.encoded), path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attrs) == true)
        #expect(attrs["Colors"] == .array([.string("red"), .string("blue")]))
    }
    @Test func repeatedCaptureNamesMustMatchEarlierValues() throws {
        let dir = TempDir(); let path = dir.file("Ada-Bob-Ada-2026-03-15-15_03_2026.txt")
        var first = CustomTextCondition(); first.names = "Person"; first.pattern = "^(Ada)"
        var second = CustomTextCondition(); second.names = "Person"; second.pattern = "-(Bob)-"
        var attrs: [String: JSONValue] = [:]
        func check(_ spec: CustomTextCondition, _ attrs: inout [String: JSONValue]) throws -> Bool? {
            try ConditionEvaluator.evaluateWithContext(makeCondition(.customTextMatch, .is, spec.encoded), path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attrs)
        }
        #expect(try check(first, &attrs) == true)
        #expect(try check(second, &attrs) == false)
        #expect(attrs["Person"] == .string("Ada"))
        second.pattern = "-(Bob|Ada)"
        #expect(try check(second, &attrs) == true)
        var date1 = CustomDateCondition(); date1.name = "Date"; date1.pattern = "(\\d{4}-\\d{2}-\\d{2})"
        var date2 = CustomDateCondition(); date2.name = "Date"; date2.pattern = "(\\d{2}_\\d{2}_\\d{4})"; date2.format = "dd_MM_yyyy"
        #expect(try ConditionEvaluator.evaluateWithContext(makeCondition(.customDateMatch, .is, date1.encoded), path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attrs) == true)
        #expect(try ConditionEvaluator.evaluateWithContext(makeCondition(.customDateMatch, .is, date2.encoded), path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attrs) == true)
        var table = CustomTableCondition(); table.prefix = "People"; table.matchColumn = "Name"; table.table = "Name\tID\nAda\t42"
        #expect(try ConditionEvaluator.evaluateWithContext(makeCondition(.customTableMatch, .is, table.encoded), path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attrs) == true)
        table.table = "Name\tID\nAda\t73"
        #expect(try ConditionEvaluator.evaluateWithContext(makeCondition(.customTableMatch, .is, table.encoded), path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attrs) == false)
        #expect(attrs["People.ID"] == .string("42"))
    }
    @Test func customTextCapturesFeedLaterConditionAndRename() throws {
        let dir = TempDir(); let path = dir.file("invoice-Ada-42.txt")
        var spec = CustomTextCondition(); spec.names = "Person, ID"; spec.pattern = "invoice-(\\w+)-(\\d+)"
        let capture = Condition(ruleId: "r", kind: .customTextMatch, operator: .is, value: spec.encoded)
        let check = SpotlightCondition(key: "Person", type: .text, operand: "Ada")
        let later = Condition(ruleId: "r", kind: .scriptAttribute, operator: .is, value: check.encoded)
        let rename = makeAction(.rename, .object([ActionParam.pattern: .string("dynamic"), HazelPattern.tokensKey: .array([
            .object(["type": .string("attribute"), "value": .string("ID")]), .object(["type": .string("extension")])
        ])]))
        let rule = makeRule(name: "capture", conditions: [capture, later], actions: [rename])
        let result = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "capture")
        #expect(result.history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: "\(dir.path)/42.txt"))
        spec.names = "Person, Person"
        #expect(spec.validationError != nil)
    }
    @Test func alternativeCapturesFailClosedWhenSelectedBranchLacksValue() throws {
        let dir = TempDir()
        var first = CustomTextCondition(); first.names = "Person"; first.pattern = "^person-(.+)$"
        var second = CustomTextCondition(); second.names = "ID"; second.pattern = "^code-(\\d+)$"
        let conditions = [Condition(ruleId: "r", kind: .customTextMatch, operator: .is, value: first.encoded),
                          Condition(ruleId: "r", kind: .customTextMatch, operator: .is, value: second.encoded)]
        let rename = makeAction(.rename, .object([ActionParam.pattern: .string("dynamic"), HazelPattern.tokensKey: .array([
            .object(["type": .string("attribute"), "value": .string("ID")]), .object(["type": .string("extension")])
        ])]))
        var rule = makeRule(name: "alternative capture", conditions: conditions, actions: [rename]); rule.conditionMatch = .any
        let missing = dir.file("person-Ada.txt")
        let failed = RuleEngine.run(path: missing, depth: 0, rules: [rule], batchId: "missing")
        #expect(failed.history.first?.status == .failed)
        #expect(FileManager.default.fileExists(atPath: missing))
        let available = dir.file("code-42.txt")
        let applied = RuleEngine.run(path: available, depth: 0, rules: [rule], batchId: "available")
        #expect(applied.history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: "\(dir.path)/42.txt"))
    }
    @Test func customDateCaptureFeedsLaterDateConditionAndRename() throws {
        let dir = TempDir(); let path = dir.file("invoice-2026-03-15.txt")
        var spec = CustomDateCondition(); spec.name = "Invoice date"; spec.pattern = "(\\d{4}-\\d{2}-\\d{2})"
        let condition = Condition(ruleId: "r", kind: .customDateMatch, operator: .is, value: spec.encoded)
        var attributes: [String: JSONValue] = [:]
        #expect(try ConditionEvaluator.evaluateWithContext(condition, path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attributes) == true)
        let later = SpotlightCondition(key: "Invoice date", type: .date, operand: "2020-01-01T00:00:00Z")
        let comparison = Condition(ruleId: "r", kind: .scriptAttribute, operator: .greaterThan, value: later.encoded)
        #expect(try ConditionEvaluator.evaluateWithContext(comparison, path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attributes) == true)
        let rename = makeAction(.rename, .object([ActionParam.pattern: .string("dynamic"), HazelPattern.tokensKey: .array([
            .object(["type": .string("attributeDate"), "source": .string("Invoice date"), "value": .string("yyyy-MM")]),
            .object(["type": .string("extension")])
        ])]))
        let rule = makeRule(name: "date", conditions: [condition, comparison], actions: [rename])
        let result = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "date")
        #expect(result.history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: "\(dir.path)/2026-03.txt"))
        spec.pattern = "(\\d+)(\\d+)"
        #expect(spec.validationError != nil)
    }
    @Test func customDateAndTableWorkFromWatcher() throws {
        let dir = TempDir(); let folder = WatchedFolder(path: dir.path); let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        var dateSpec = CustomDateCondition(); dateSpec.name = "Day"; dateSpec.pattern = "^date-(\\d{4}-\\d{2}-\\d{2})$"
        var tableSpec = CustomTableCondition(); tableSpec.prefix = "People"; tableSpec.matchColumn = "Name"; tableSpec.table = "Name\tID\nAda\t42"
        let dateCondition = makeCondition(.customDateMatch, .is, dateSpec.encoded)
        let tableCondition = makeCondition(.customTableMatch, .is, tableSpec.encoded)
        let dateAction = makeAction(.rename, .object([ActionParam.pattern: .string("dynamic"), HazelPattern.tokensKey: .array([
            .object(["type": .string("attributeDate"), "source": .string("Day"), "value": .string("yyyy-MM")]), .object(["type": .string("extension")])
        ])]))
        let tableAction = makeAction(.rename, .object([ActionParam.pattern: .string("dynamic"), HazelPattern.tokensKey: .array([
            .object(["type": .string("attribute"), "value": .string("People.ID")]), .object(["type": .string("extension")])
        ])]))
        var dateRule = makeRule(folderId: folder.id, name: "date", conditions: [dateCondition], actions: [dateAction])
        var tableRule = makeRule(folderId: folder.id, name: "table", conditions: [tableCondition], actions: [tableAction])
        dateRule.conditions[0].ruleId = dateRule.id; dateRule.actions[0].ruleId = dateRule.id
        tableRule.conditions[0].ruleId = tableRule.id; tableRule.actions[0].ruleId = tableRule.id
        try db.insertRule(dateRule); try db.insertRule(tableRule)
        let datePath = dir.file("date-2026-03-15.txt"); let tablePath = dir.file("Ada.txt")
        WatcherCoordinator(db: db).handle(path: datePath)
        WatcherCoordinator(db: db).handle(path: tablePath)
        #expect(FileManager.default.fileExists(atPath: "\(dir.path)/2026-03.txt"))
        #expect(FileManager.default.fileExists(atPath: "\(dir.path)/42.txt"))
    }
    @Test func customTableMatchProducesReusableRowValues() throws {
        let dir = TempDir(); let path = dir.file("Invoice Ada.pdf")
        var table = CustomTableCondition()
        table.prefix = "People"; table.matchColumn = "Name"; table.table = "Name\tID\nAda\t42\nGrace\t73"
        let condition = Condition(ruleId: "r", kind: .customTableMatch, operator: .is, value: table.encoded)
        var attributes: [String: JSONValue] = [:]
        #expect(try ConditionEvaluator.evaluateWithContext(condition, path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attributes) == true)
        #expect(attributes["People.ID"] == .string("42"))
        let value = SpotlightCondition(key: "People.ID", type: .text, operand: "42")
        let subsequent = Condition(ruleId: "r", kind: .scriptAttribute, operator: .is, value: value.encoded)
        #expect(try ConditionEvaluator.evaluateWithContext(subsequent, path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attributes) == true)
        let rename = makeAction(.rename, .object([ActionParam.pattern: .string("dynamic"), HazelPattern.tokensKey: .array([
            .object(["type": .string("attribute"), "value": .string("People.ID")]),
            .object(["type": .string("extension")])
        ])]))
        let rule = makeRule(name: "table", conditions: [condition, subsequent], actions: [rename])
        let preview = try #require(RuleEngine.previewFile(path: path, depth: 0, rules: [rule]))
        #expect(preview.rules.first?.actions.first?.targetPath == "\(dir.path)/42.pdf")
        let run = RuleEngine.run(path: path, depth: 0, rules: [rule], batchId: "table")
        #expect(run.history.first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: "\(dir.path)/42.pdf"))
        table.table = "Name\tName\nAda\t42"
        #expect(table.validationError != nil)
    }
    @Test func scriptOutputsCanBeComparedInLaterConditions() throws {
        let dir = TempDir()
        let path = dir.file("sample.txt")
        let spec = SpotlightCondition(key: "People list", type: .text, operand: "Ada")
        let child = Condition(ruleId: "r", kind: .scriptAttribute, operator: .is, value: spec.encoded)
        var attributes: [String: JSONValue] = ["People list": .array([.string("Ada"), .string("Grace")])]
        #expect(try ConditionEvaluator.evaluateWithContext(child, path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attributes) == true)
        let not = Condition(ruleId: "r", kind: .conditionGroup, operator: .is, value: ConditionGroup(match: .none, conditions: [child]).encoded)
        attributes.removeAll()
        #expect(try ConditionEvaluator.evaluateWithContext(not, path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attributes) == nil)
        let dateSpec = SpotlightCondition(key: "Date", type: .date, operand: "2020-01-01T00:00:00Z")
        let date = Condition(ruleId: "r", kind: .scriptAttribute, operator: .greaterThan, value: dateSpec.encoded)
        attributes["Date"] = .object(["__forelDate": .number(1_600_000_000)])
        #expect(try ConditionEvaluator.evaluateWithContext(date, path: path, depth: 0, lastOpened: SpotlightLastOpenedMetadata(), attributes: &attributes) == true)
    }
    @Test func scalarAndListComparisonsAreTyped() {
        let text = SpotlightCondition(key: "kMDItemAuthors", type: .text, operand: "Ana")
        #expect(text.compare(["Ana", "René"], operator: .is) == true)
        #expect(text.compare(["Ana", "René"], operator: .isNot) == false)
        #expect(text.compare(["Bob", "René"], operator: .isNot) == true)
        #expect(text.compare(["Ana", 2], operator: .is) == true)
        #expect(text.compare(["Ana", 2], operator: .isNot) == false)
        #expect(text.compare(["Bob", 2], operator: .is) == nil)
        let number = SpotlightCondition(key: "kMDItemPixelWidth", type: .number, operand: "100")
        #expect(number.compare([20, 200], operator: .greaterThan) == true)
        #expect(number.compare(NSNumber(value: true), operator: .is) == nil)
        let bool = SpotlightCondition(key: "someFlag", type: .boolean, operand: "true")
        #expect(bool.compare(NSNumber(value: true), operator: .is) == true)
        #expect(bool.compare(NSNumber(value: 1), operator: .is) == nil)
        let date = SpotlightCondition(key: "kMDItemContentCreationDate", type: .date, operand: "2020-01-01T00:00:00Z")
        #expect(date.compare(Date(timeIntervalSince1970: 1_600_000_000), operator: .greaterThan) == true)
        #expect(SpotlightCondition.decode(date.encoded) == date)
    }

    @Test func invalidOrUnavailableAttributesDoNotMatchNegation() throws {
        let dir = TempDir()
        let path = dir.file("sample.txt")
        let spec = SpotlightCondition(key: "kMDItemForelNonexistentAttribute", type: .text, operand: "secret")
        let condition = Condition(ruleId: "r", kind: .spotlightAttribute, operator: .is, value: spec.encoded)
        let not = Condition(ruleId: "r", kind: .conditionGroup, operator: .is,
                            value: ConditionGroup(match: .none, conditions: [condition]).encoded)
        #expect(!ConditionEvaluator.evaluate(condition, path: path))
        #expect(!ConditionEvaluator.evaluate(not, path: path))
        let invalid = SpotlightCondition(key: "", type: .number, operand: "NaN")
        #expect(invalid.validationError(for: .is) != nil)
        let incompatible = SpotlightCondition(key: "kMDItemPixelWidth", type: .number, operand: "3")
        #expect(incompatible.validationError(for: .contains) != nil)
    }
}
