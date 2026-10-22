import Testing
import Foundation
@testable import ForelCore

@Suite struct RuleValidatorTests {
    // MARK: - Conditions

    @Test func validConditionProducesNoIssues() {
        let conditions = [makeCondition(.extension_, .is, "pdf")]
        #expect(RuleValidator.validate(conditions).isEmpty)
    }

    @Test func conditionWithEmptyValueReportsIssue() {
        let conditions = [makeCondition(.extension_, .is, "")]
        #expect(RuleValidator.validate(conditions) == [.init(message: "Condition value cannot be empty")])
    }

    @Test func conditionWithWhitespaceOnlyValueReportsIssue() {
        let conditions = [makeCondition(.name, .contains, "   ")]
        #expect(RuleValidator.validate(conditions) == [.init(message: "Condition value cannot be empty")])
    }

    @Test func conditionWithInvalidRegexReportsIssue() {
        let conditions = [makeCondition(.name, .matchesRegex, "[invalid")]
        #expect(RuleValidator.validate(conditions) == [.init(message: "Regex pattern is invalid")])
    }

    @Test func conditionWithValidRegexProducesNoIssues() {
        let conditions = [makeCondition(.name, .matchesRegex, "^file\\d+\\.txt$")]
        #expect(RuleValidator.validate(conditions).isEmpty)
    }

    @Test func multipleInvalidConditionsReportAllIssues() {
        let conditions = [
            makeCondition(.extension_, .is, ""),
            makeCondition(.name, .matchesRegex, "[invalid"),
        ]
        let issues = RuleValidator.validate(conditions)
        #expect(issues.count == 2)
    }

    // MARK: - Actions

    @Test func moveToFolderWithValidDestinationProducesNoIssues() {
        let actions = [makeAction(.moveToFolder, .object(["destination": .string("/some/path")]))]
        #expect(RuleValidator.validate(actions).isEmpty)
    }

    @Test func moveToFolderWithEmptyDestinationReportsIssue() {
        let actions = [makeAction(.moveToFolder, .object(["destination": .string("")]))]
        #expect(RuleValidator.validate(actions) == [.init(message: "Destination path cannot be empty")])
    }

    @Test func moveToFolderWithMissingDestinationReportsIssue() {
        let actions = [makeAction(.moveToFolder, .object([:]))]
        #expect(RuleValidator.validate(actions) == [.init(message: "Destination path cannot be empty")])
    }

    @Test func copyToFolderWithValidDestinationProducesNoIssues() {
        let actions = [makeAction(.copyToFolder, .object(["destination": .string("/some/path")]))]
        #expect(RuleValidator.validate(actions).isEmpty)
    }

    @Test func copyToFolderWithEmptyDestinationReportsIssue() {
        let actions = [makeAction(.copyToFolder, .object(["destination": .string("")]))]
        #expect(RuleValidator.validate(actions) == [.init(message: "Destination path cannot be empty")])
    }

    @Test func renameWithValidPatternProducesNoIssues() {
        let actions = [makeAction(.rename, .object(["pattern": .string("{name}")]))]
        #expect(RuleValidator.validate(actions).isEmpty)
    }

    @Test func renameWithEmptyPatternReportsIssue() {
        let actions = [makeAction(.rename, .object(["pattern": .string("")]))]
        #expect(RuleValidator.validate(actions) == [.init(message: "Rename pattern cannot be empty")])
    }

    @Test func renameWithMissingPatternReportsIssue() {
        let actions = [makeAction(.rename, .object([:]))]
        #expect(RuleValidator.validate(actions) == [.init(message: "Rename pattern cannot be empty")])
    }

    @Test func addTagWithValidTagProducesNoIssues() {
        let actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["Project"])]))]
        #expect(RuleValidator.validate(actions).isEmpty)
    }

    @Test func addTagWithEmptyTagsReportsIssue() {
        let actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray([])]))]
        #expect(RuleValidator.validate(actions) == [.init(message: "At least one tag is required")])
    }

    @Test func addTagWithMissingTagsReportsIssue() {
        let actions = [makeAction(.addTag, .object([:]))]
        #expect(RuleValidator.validate(actions) == [.init(message: "At least one tag is required")])
    }

    @Test func addTagWithOnlyBlankTagsReportsIssue() {
        let actions = [makeAction(.addTag, .object([ActionParam.tags: .stringArray(["  "])]))]
        #expect(RuleValidator.validate(actions) == [.init(message: "At least one tag is required")])
    }

    @Test func removeTagWithMissingTagsReportsIssue() {
        let actions = [makeAction(.removeTag, .object([:]))]
        #expect(RuleValidator.validate(actions) == [.init(message: "At least one tag is required")])
    }

    @Test func openApplicationWithValidApplicationProducesNoIssues() {
        let actions = [makeAction(.openApplication, .object([ActionParam.applicationPath: .string("/Applications/TextEdit.app")]))]
        #expect(RuleValidator.validate(actions).isEmpty)
    }

    @Test func openApplicationWithMissingApplicationReportsIssue() {
        let actions = [makeAction(.openApplication, .object([:]))]
        #expect(RuleValidator.validate(actions) == [.init(message: "Application cannot be empty")])
    }

    @Test func localFileActionsValidateRequiredDestinations() {
        let validSort = makeAction(.sortIntoSubfolder, .object([ActionParam.subfolder: .string("Invoices/2026")]))
        let unsafeSort = makeAction(.sortIntoSubfolder, .object([ActionParam.subfolder: .string("../Outside")]))
        let missingSync = makeAction(.syncToFolder, .object([:]))
        let missingAlias = makeAction(.makeAlias, .object([:]))

        #expect(RuleValidator.validate([validSort]).isEmpty)
        #expect(RuleValidator.validate([unsafeSort]) == [.init(message: "Subfolder must be a relative path")])
        #expect(RuleValidator.validate([missingSync]) == [.init(message: "Destination path cannot be empty")])
        #expect(RuleValidator.validate([missingAlias]) == [.init(message: "Alias destination cannot be empty")])
    }

    @Test func unrelatedActionProducesNoIssues() {
        let actions = [makeAction(.moveToTrash, .object([:]))]
        #expect(RuleValidator.validate(actions).isEmpty)
    }

    @Test func multipleInvalidActionsReportAllIssues() {
        let actions = [
            makeAction(.moveToFolder, .object(["destination": .string("")])),
            makeAction(.rename, .object(["pattern": .string("")])),
            makeAction(.addTag, .object([ActionParam.tags: .stringArray([])])),
            makeAction(.openApplication, .object([ActionParam.applicationPath: .string("  ")])),
        ]
        let issues = RuleValidator.validate(actions)
        #expect(issues.count == 4)
    }

    @Test func mixedValidAndInvalidActionReportsOnlyInvalid() {
        let actions = [
            makeAction(.moveToFolder, .object(["destination": .string("/valid")])),
            makeAction(.rename, .object(["pattern": .string("")])),
        ]
        #expect(RuleValidator.validate(actions) == [.init(message: "Rename pattern cannot be empty")])
    }
}
