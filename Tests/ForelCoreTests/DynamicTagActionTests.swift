import Foundation
import Testing
@testable import ForelCore

@Suite struct DynamicTagActionTests {
    @Test func listAttributeExpandsIntoIndividualGeneratedTags() throws {
        let dir = TempDir(), file = dir.file("item.txt")
        var context = HazelPatternContext(path: file)
        context.attributes["topics"] = .stringArray(["one", "two"])
        let action = makeAction(.addTag, .object([HazelPattern.tokensKey: .array([
            .object(["type": .string("literal"), "value": .string("topic-")]),
            .object(["type": .string("attributeList"), "value": .string("topics"), "selection": .string("all")])
        ])]))
        let result = try ActionExecutor.execute(action, path: file, hazelContext: context)
        #expect(try FinderTags.readChecked(file) == ["topic-one", "topic-two"])
        try ActionExecutor.revert(result.undo)
        #expect(try FinderTags.readChecked(file).isEmpty)
    }
    @Test func generatedTagUsesContextAndPreviewAfterMove() throws {
        let dir = TempDir(), destination = TempDir()
        let original = dir.file("report.txt")
        let future = (destination.path as NSString).appendingPathComponent("report.txt")
        let action = makeAction(.addTag, .object([
            HazelPattern.tokensKey: .array([.object(["type": .string("name")])])
        ]))
        let context = HazelPatternContext(path: original)
        let plan = try ActionExecutor.plan(action, path: future, contextPath: original, hazelContext: context)
        #expect(plan.status == .wouldRun)
        let result = try ActionExecutor.execute(action, path: original, contextPath: original, hazelContext: context)
        #expect(try FinderTags.readChecked(original) == ["report"])
        try ActionExecutor.revert(result.undo)
        #expect(try FinderTags.readChecked(original).isEmpty)
    }

    @Test func removeAllRestoresExactColoredTagsAndLeavesLabel() throws {
        let dir = TempDir(), file = dir.file("item.txt")
        let tags = ["Red", "Project\n4", "Other\n6"]
        try (URL(fileURLWithPath: file) as NSURL).setResourceValue(NSNumber(value: 6), forKey: .labelNumberKey)
        try FinderTags.write(file, tags)
        let label = try URL(fileURLWithPath: file).resourceValues(forKeys: [.labelNumberKey]).labelNumber
        let action = makeAction(.removeTag, .object(["remove_all_tags": .bool(true)]))
        let result = try ActionExecutor.execute(action, path: file)
        #expect(try FinderTags.readChecked(file).isEmpty)
        #expect(try URL(fileURLWithPath: file).resourceValues(forKeys: [.labelNumberKey]).labelNumber == 0)
        try ActionExecutor.revert(result.undo)
        #expect(Set(try FinderTags.readChecked(file)) == Set(tags))
        #expect(try URL(fileURLWithPath: file).resourceValues(forKeys: [.labelNumberKey]).labelNumber == label)
    }

    @Test func tagUndoRejectsLaterLabelChanges() throws {
        let dir = TempDir(), file = dir.file("item.txt")
        try FinderTags.write(file, ["Project\n4"])
        let result = try ActionExecutor.execute(makeAction(.removeTag, .object(["remove_all_tags": .bool(true)])), path: file)
        try (URL(fileURLWithPath: file) as NSURL).setResourceValue(NSNumber(value: 6), forKey: .labelNumberKey)
        #expect(throws: ActionError.self) { try ActionExecutor.revert(result.undo) }
        #expect(try URL(fileURLWithPath: file).resourceValues(forKeys: [.labelNumberKey]).labelNumber == 6)
    }

    @Test func removeNamedTagPreservesOtherColorsAndUndo() throws {
        let dir = TempDir(), file = dir.file("item.txt")
        try FinderTags.write(file, ["Project\n4", "Keep\n6"])
        let action = makeAction(.removeTag, .object([ActionParam.tags: .stringArray(["Project"])]))
        let result = try ActionExecutor.execute(action, path: file)
        #expect(try FinderTags.readChecked(file) == ["Keep\n6"])
        try ActionExecutor.revert(result.undo)
        #expect(Set(try FinderTags.readChecked(file)) == Set(["Project\n4", "Keep\n6"]))
    }
}
