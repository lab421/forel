import Foundation
import Testing
@testable import ForelCore

@Suite struct FinderCommentTests {
    @Test func commentPatternsConditionsAndUndo() throws {
        let dir = TempDir()
        let file = dir.file("comment.txt")
        #expect(try FinderComment.read(file) == nil)
        let first = makeAction(.setFinderComment, .object([ActionParam.comment: .string("First")]))
        #expect(try ActionExecutor.plan(first, path: file).status == .wouldRun)
        #expect(try FinderComment.read(file) == nil)
        let initial = try ActionExecutor.execute(first, path: file)
        #expect(try FinderComment.read(file) == "First")
        #expect(ConditionEvaluator.evaluate(makeCondition(.finderComment, .contains, "irst"), path: file))
        let append = makeAction(.setFinderComment, .object([HazelPattern.tokensKey: .array([
            .object(["type": .string("comment")]), .object(["type": .string("literal"), "value": .string(" / new")])
        ])]))
        let applied = try ActionExecutor.execute(append, path: file)
        #expect(try FinderComment.read(file) == "First / new")
        try ActionExecutor.revert(Undo.fromJSON(applied.undo.toJSON()))
        #expect(try FinderComment.read(file) == "First")
        try ActionExecutor.revert(Undo.fromJSON(initial.undo.toJSON()))
        #expect(try FinderComment.read(file) == nil)
    }
}
