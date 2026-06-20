import Testing
import Foundation
@testable import ForelCore

@Suite struct PlanValidatorTests {
    @Test func twoDifferentFilesPlannedToTheSameDestinationAreBlocked() throws {
        // Two same-named files in different subfolders, both collected into
        // one flat destination — exactly the collision a single file's plan
        // can never see on its own.
        let dir = TempDir()
        let subA = dir.dir("A")
        let subB = dir.dir("B")
        let fileA = (subA as NSString).appendingPathComponent("photo.jpg")
        let fileB = (subB as NSString).appendingPathComponent("photo.jpg")
        try "a".write(toFile: fileA, atomically: true, encoding: .utf8)
        try "b".write(toFile: fileB, atomically: true, encoding: .utf8)
        let destination = dir.dir("Pics")

        var rule = makeRule(name: "collect photos", conditions: [makeCondition(.extension_, .is, "jpg")], recursionDepth: nil)
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path)

        let result = PlanValidator.validate(plan)

        #expect(result.status == .blocked)
        #expect(result.conflicts.contains { $0.message.contains("Multiple files would be written") })
    }

    /// `moveToFolder` always resolves a same-name destination itself
    /// (rename or replace), so it never reaches the validator's
    /// `destinationExists` conflict path. `copyToFolder` has no such
    /// resolution param and still relies on it.
    @Test func existingDestinationRespectsConflictPolicy() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        try "x".write(toFile: (destination as NSString).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = dir.file("a.txt")

        var rule = makeRule(name: "archive", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.copyToFolder, .object(["destination": .string(destination)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path)

        let blockResult = PlanValidator.validate(plan, policy: .blockOnExistingDestination)
        #expect(blockResult.status == .blocked)

        let confirmResult = PlanValidator.validate(plan, policy: .confirmOnExistingDestination)
        #expect(confirmResult.status == .needsConfirmation)
    }

    @Test func alreadyInDestinationNeverCountsAsAConflict() throws {
        let dir = TempDir()
        let pdfDir = dir.dir("PDF")
        let existing = (pdfDir as NSString).appendingPathComponent("existing.pdf")
        try "x".write(toFile: existing, atomically: true, encoding: .utf8)

        var rule = makeRule(name: "sort pdf", conditions: [makeCondition(.extension_, .is, "pdf")], recursionDepth: nil)
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(pdfDir)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path)

        let result = PlanValidator.validate(plan)
        #expect(result.status == .valid)
        #expect(result.conflicts.isEmpty)
    }

    @Test func movingAFolderIntoItselfIsBlocked() throws {
        let dir = TempDir()
        let target = dir.dir("Target")

        var rule = makeRule(name: "move folder", conditions: [makeCondition(.name, .is, "Target")], recursionDepth: nil)
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(target)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path)

        let result = PlanValidator.validate(plan)
        #expect(result.status == .blocked)
        #expect(result.conflicts.contains { $0.message.contains("into itself") })
    }

    @Test func movingAFolderIntoItsOwnDescendantIsBlocked() throws {
        let dir = TempDir()
        let target = dir.dir("Target")
        let sub = (target as NSString).appendingPathComponent("Sub")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)

        var rule = makeRule(name: "move folder", conditions: [makeCondition(.name, .is, "Target")], recursionDepth: nil)
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(sub)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path)

        let result = PlanValidator.validate(plan)
        #expect(result.status == .blocked)
        #expect(result.conflicts.contains { $0.message.contains("into itself") })
    }

    @Test func fileModifiedBetweenDryRunAndRunNowMarksThePlanStale() throws {
        let dir = TempDir()
        let file = dir.file("a.txt", contents: "v1")
        var rule = makeRule(name: "tag", conditions: [makeCondition(.extension_, .is, "txt")])
        rule.actions = [makeAction(.addTag, .object(["tag": .string("Seen")]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path)

        try "v2-longer-content".write(toFile: file, atomically: true, encoding: .utf8)

        let result = PlanValidator.validate(plan)
        #expect(result.status == .blocked)
        #expect(result.conflicts.contains { $0.message.contains("changed") })
    }

    @Test func dryRunRunNowAndWatcherAgreeOnValidationForTheSameInputs() throws {
        let dir = TempDir()
        let pdfDir = dir.dir("PDF")
        let existing = (pdfDir as NSString).appendingPathComponent("existing.pdf")
        try "x".write(toFile: existing, atomically: true, encoding: .utf8)

        var rule = makeRule(name: "sort pdf", conditions: [makeCondition(.extension_, .is, "pdf")], recursionDepth: nil)
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(pdfDir)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let dryRunPlan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .previewed)
        let runNowPlan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path, status: .ready)
        let watcherPlan = RulePlanner.planFile(path: existing, depth: RuleEngine.pathDepth(root: dir.path, path: existing) ?? 0, rules: [rule], root: dir.path)
            .map { ExecutionPlan(status: .ready, files: [$0]) }

        let dryRunResult = PlanValidator.validate(dryRunPlan)
        let runNowResult = PlanValidator.validate(runNowPlan)
        let watcherResult = PlanValidator.validate(try #require(watcherPlan))

        #expect(dryRunResult.status == runNowResult.status)
        #expect(dryRunResult.status == watcherResult.status)
    }

    @Test func planExecutorRefusesBothActionsOnAGenuineDestinationCollision() throws {
        let dir = TempDir()
        let subA = dir.dir("A")
        let subB = dir.dir("B")
        let fileA = (subA as NSString).appendingPathComponent("photo.jpg")
        let fileB = (subB as NSString).appendingPathComponent("photo.jpg")
        try "a".write(toFile: fileA, atomically: true, encoding: .utf8)
        try "b".write(toFile: fileB, atomically: true, encoding: .utf8)
        let destination = dir.dir("Pics")

        var rule = makeRule(name: "collect photos", conditions: [makeCondition(.extension_, .is, "jpg")], recursionDepth: nil)
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string(destination)]), position: 0)]

        let entries = RuleEngine.walkEntries(root: dir.path, maxDepth: nil)
        let plan = RulePlanner.plan(entries: entries, rules: [rule], root: dir.path)
        let result = PlanExecutor.execute(plan)

        let collidingPath = (destination as NSString).appendingPathComponent("photo.jpg")
        // Neither source file moved — both stayed where they were.
        #expect(FileManager.default.fileExists(atPath: fileA))
        #expect(FileManager.default.fileExists(atPath: fileB))
        #expect(!FileManager.default.fileExists(atPath: collidingPath))
        #expect(result.history.contains { $0.message?.contains("would also write to") == true })
    }
}
