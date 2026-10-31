import Foundation
import Testing
@testable import ForelCore

@Suite struct FinderColorCompatibilityTests {
    @Test func legacyLabelAndCustomColoredTagsAreSynchronizedAndRestored() throws {
        let dir = TempDir()
        let path = dir.file("labels.txt")
        let url = URL(fileURLWithPath: path) as NSURL
        try url.setResourceValue(NSNumber(value: 6), forKey: .labelNumberKey)
        try FinderTags.write(path, ["Red", "Project\n4", "Old\n6", "Keep"])
        let action = makeAction(.setFinderLabel, .object([ActionParam.color: .string("Blue")]))
        #expect(try ActionExecutor.plan(action, path: path).status == .wouldRun)
        let applied = try ActionExecutor.execute(action, path: path)
        #expect(try ActionExecutor.finderLabel(path) == 4)
        #expect(try FinderTags.readChecked(path) == ["Red", "Project\n4", "Keep"])
        #expect(!ConditionEvaluator.evaluate(makeCondition(.colorLabel, .is, "Red"), path: path))
        #expect(ConditionEvaluator.evaluate(makeCondition(.colorLabel, .is, "Blue"), path: path))
        #expect(try ActionExecutor.plan(action, path: path).status == .wouldSkip)
        let undo = Undo.fromJSON(applied.undo.toJSON())
        #expect(undo == applied.undo)
        try ActionExecutor.revert(undo)
        #expect(try ActionExecutor.finderLabel(path) == 6)
        #expect(Set(try FinderTags.readChecked(path)) == Set(["Red", "Project\n4", "Old\n6", "Keep"]))
    }

    @Test func matchingFirstTagDoesNotHideOtherColors() throws {
        let dir = TempDir()
        let path = dir.file("mixed.txt")
        try (URL(fileURLWithPath: path) as NSURL).setResourceValue(NSNumber(value: 4), forKey: .labelNumberKey)
        try FinderTags.write(path, ["Blue custom\n4", "Red custom\n6"])
        let action = makeAction(.setColorLabel, .object([ActionParam.color: .string("Blue")]))
        #expect(ActionExecutor.wouldChange(action, path: path))
        #expect(try ActionExecutor.plan(action, path: path).status == .wouldRun)
        _ = try ActionExecutor.execute(action, path: path)
        #expect(try FinderTags.readChecked(path) == ["Blue custom\n4"])
    }

    @Test func changedLabelOrColoredTagsPreventUndo() throws {
        let dir = TempDir()
        let path = dir.file("changed.txt")
        let applied = try ActionExecutor.execute(makeAction(.setFinderLabel, .object([ActionParam.color: .string("Blue")])), path: path)
        try (URL(fileURLWithPath: path) as NSURL).setResourceValue(NSNumber(value: 6), forKey: .labelNumberKey)
        #expect(throws: ActionError.self) { try ActionExecutor.revert(applied.undo) }
        #expect(try FinderTags.readChecked(path) == ["Blue\n4"])
    }
}
