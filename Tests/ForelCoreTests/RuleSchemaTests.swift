import Testing
import Foundation
@testable import ForelCore

/// Guards the central feature catalog (`RuleSchema`) against drifting away from
/// the engine. The catalog is the single source of truth the UI reads; these
/// tests make sure every operator it declares for a condition is actually
/// implemented by `ConditionEvaluator`, and that the action catalog stays
/// internally consistent.
@Suite struct RuleSchemaTests {
    // MARK: - Catalog structural invariants

    @Test func everyConditionKindHasOperatorsAndAValidDefault() {
        for kind in RuleSchema.conditionKinds {
            #expect(!kind.validOperators.isEmpty, "\(kind) has no operators")
            #expect(kind.validOperators.contains(kind.defaultOperator), "\(kind) default operator not in its valid set")
            #expect(!kind.label.isEmpty)
        }
        #expect(!RuleSchema.conditionKinds.contains(.rawWhereFromMetadata))
    }

    @Test func everyActionKindHasLabelIconAndUniqueParamKeys() {
        for kind in RuleSchema.actionKinds {
            #expect(!kind.label.isEmpty)
            #expect(!kind.iconSystemName.isEmpty)
            let keys = kind.params.map(\.key)
            #expect(Set(keys).count == keys.count, "\(kind) has duplicate param keys")
            #expect(keys.allSatisfy { !$0.isEmpty })
        }
    }

    @Test func hasOptionsMatchesActionsThatExposeAnOptionsPopover() {
        let expectedWithOptions: Set<ActionKind> = [.moveToFolder, .copyToFolder, .runShortcut, .rename, .importToLibrary]
        for kind in RuleSchema.actionKinds {
            #expect(kind.hasOptions == expectedWithOptions.contains(kind), "\(kind) hasOptions mismatch")
        }
    }

    @Test func valueKindResolutionHonoursOperatorOverrides() {
        // Regex operator always wins.
        #expect(RuleSchema.valueKind(for: .name, operator: .matchesRegex) == .regex)
        // Date kinds switch between absolute and relative editors by operator.
        #expect(RuleSchema.valueKind(for: .createdAt, operator: .before) == .absoluteDate)
        #expect(RuleSchema.valueKind(for: .createdAt, operator: .withinLast) == .relativeDate)
        // Non-date kinds keep their base editor.
        #expect(RuleSchema.valueKind(for: .sizeBytes, operator: .greaterThan) == .size)
        #expect(RuleSchema.valueKind(for: .colorLabel, operator: .is) == .colorLabel)
        // downloadedWithApp gets the installed-apps picker and only supports
        // exact app selection in the editor.
        #expect(RuleSchema.valueKind(for: .downloadedWithApp, operator: .is) == .appPicker)
        // The remaining user-facing metadata kind stays plain text.
        #expect(RuleSchema.valueKind(for: .downloadedFromWebsite, operator: .is) == .text)
    }

    // MARK: - Engine handles every declared operator

    /// For each condition kind, builds one value that *should* match per valid
    /// operator, and asserts the evaluator returns true. The `keys ==
    /// validOperators` check is the anti-drift guard: add an operator to the
    /// catalog and this fails until a matching fixture (and engine support) exists.

    @Test func stringKindsMatchEveryDeclaredOperator() {
        let dir = TempDir()
        let file = dir.file("report.txt", contents: "the quarterly report")
        let fixtures: [ConditionKind: [Operator: String]] = [
            .name: [
                .is: "report", .isNot: "nope", .contains: "epo", .doesNotContain: "zzz",
                .startsWith: "rep", .endsWith: "ort", .matchesRegex: "^rep.*",
            ],
            .contents: [
                .is: "the quarterly report", .isNot: "report", .contains: "quarter",
                .doesNotContain: "annual", .startsWith: "the", .endsWith: "report",
                .matchesRegex: "quarterly\\s+report",
            ],
        ]
        for (kind, values) in fixtures {
            assertExhaustive(kind, values)
            for (op, value) in values {
                #expect(ConditionEvaluator.evaluate(makeCondition(kind, op, value), path: file), "\(kind) \(op) should match")
            }
        }
    }

    @Test func sizeMatchesEveryDeclaredOperator() {
        let dir = TempDir()
        let file = dir.file("data.bin", contents: String(repeating: "x", count: 100))
        let fixtures: [Operator: String] = [.is: "100", .isNot: "50", .greaterThan: "50", .lessThan: "200"]
        assertExhaustive(.sizeBytes, fixtures)
        for (op, value) in fixtures {
            #expect(ConditionEvaluator.evaluate(makeCondition(.sizeBytes, op, value), path: file), "size \(op) should match")
        }
    }

    @Test func kindMatchesEveryDeclaredOperator() {
        let dir = TempDir()
        let file = dir.file("note.txt", contents: "hi")
        let fixtures: [Operator: String] = [.is: "text", .isNot: "image"]
        assertExhaustive(.kind, fixtures)
        for (op, value) in fixtures {
            #expect(ConditionEvaluator.evaluate(makeCondition(.kind, op, value), path: file), "kind \(op) should match")
        }
    }

    @Test func colorLabelMatchesEveryDeclaredOperator() throws {
        let dir = TempDir()
        let file = dir.file("photo.jpg", contents: "img")
        try FinderTags.setColorLabel(file, color: "Red")
        let fixtures: [Operator: String] = [.is: "Red", .isNot: "Blue"]
        assertExhaustive(.colorLabel, fixtures)
        for (op, value) in fixtures {
            #expect(ConditionEvaluator.evaluate(makeCondition(.colorLabel, op, value), path: file), "colorLabel \(op) should match")
        }
    }

    @Test func tagsMatchEveryDeclaredOperator() throws {
        let dir = TempDir()
        let file = dir.file("doc.pdf", contents: "x")
        try FinderTags.apply(file, tag: "Project", add: true)
        // Tag names are lowercased before matching, so the regex pattern must be
        // lowercase too (the evaluator does not case-fold the user's pattern).
        let fixtures: [Operator: String] = [
            .is: "project", .isNot: "other", .contains: "roj", .doesNotContain: "zzz",
            .startsWith: "pro", .endsWith: "ect", .matchesRegex: "^proj",
        ]
        assertExhaustive(.tags, fixtures)
        for (op, value) in fixtures {
            #expect(ConditionEvaluator.evaluate(makeCondition(.tags, op, value), path: file), "tags \(op) should match")
        }
    }

    @Test func downloadedFromWebsiteAndRawWhereFromMatchEveryDeclaredOperator() throws {
        let dir = TempDir()
        let file = dir.file("report.pdf")
        try setWhereFroms(file, ["https://example.com/downloads/report.pdf"])

        let fixtures: [Operator: String] = [
            .is: "https://example.com/downloads/report.pdf", .isNot: "https://other.com/",
            .contains: "example.com", .doesNotContain: "other.com",
            .startsWith: "https://example", .endsWith: "report.pdf",
            .matchesRegex: "^https://example\\.com/.*",
        ]
        for kind in [ConditionKind.downloadedFromWebsite, .rawWhereFromMetadata] {
            assertExhaustive(kind, fixtures)
            for (op, value) in fixtures {
                #expect(ConditionEvaluator.evaluate(makeCondition(kind, op, value), path: file), "\(kind) \(op) should match")
            }
        }
    }

    @Test func downloadedWithAppMatchesEveryDeclaredOperator() throws {
        let dir = TempDir()
        let file = dir.file("installer.dmg")
        try setQuarantineAgent(file, agent: "Safari")

        let fixtures: [Operator: String] = [.is: "Safari"]
        assertExhaustive(.downloadedWithApp, fixtures)
        for (op, value) in fixtures {
            #expect(ConditionEvaluator.evaluate(makeCondition(.downloadedWithApp, op, value), path: file), "downloadedWithApp \(op) should match")
        }
    }

    @Test func dateKindsMatchEveryDeclaredOperator() throws {
        let dir = TempDir()
        let file = dir.file("old.txt", contents: "x")
        let tenDaysAgo = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
        try FileManager.default.setAttributes([.modificationDate: tenDaysAgo, .creationDate: tenDaysAgo], ofItemAtPath: file)

        let fixtures: [Operator: String] = [
            .before: dayString(daysFromNow: 1),     // file (10d ago) is before tomorrow
            .after: dayString(daysFromNow: -20),    // file (10d ago) is after 20d ago
            .olderThan: "5 days",                    // file (10d ago) is older than 5 days
            .withinLast: "30 days",                  // file (10d ago) is within the last 30 days
        ]
        // createdAt and dateModified read real timestamps; dateAdded depends on
        // the volume and may be unavailable in a temp dir, so it's excluded here.
        for kind in [ConditionKind.createdAt, .dateModified] {
            assertExhaustive(kind, fixtures)
            for (op, value) in fixtures {
                #expect(ConditionEvaluator.evaluate(makeCondition(kind, op, value), path: file), "\(kind) \(op) should match")
            }
        }
    }

    // MARK: - Helpers

    private func assertExhaustive(_ kind: ConditionKind, _ fixtures: [Operator: String]) {
        #expect(Set(fixtures.keys) == Set(kind.validOperators),
                "\(kind) fixtures don't cover exactly its catalog operators — add engine support and a fixture")
    }

    private func dayString(daysFromNow: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: daysFromNow, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
