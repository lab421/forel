import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ForelCore

@Suite struct HazelLastOpenedProviderTests {
    private struct FixtureMetadata: LastOpenedMetadataProvider {
        func lastOpened(path: String) -> Date? {
            (path as NSString).lastPathComponent.hasPrefix("unseen") ? .distantPast : Date(timeIntervalSince1970: 1_900_000_000)
        }
    }

    @Test func realMoviesSeenRuleRunsWithInjectedLastOpenedDates() throws {
        guard let corpus = ProcessInfo.processInfo.environment["FOREL_HAZEL_CORPUS_2"] else { return }
        let source = TempDir()
        let destination = TempDir()
        let folder = WatchedFolder(path: source.path)
        let db = try Database(path: ":memory:")
        try db.insertFolder(folder)
        let data = try Data(contentsOf: URL(fileURLWithPath: corpus).appendingPathComponent("Movies.hazelrules"))
        let result = try RuleTransfer.importRules(from: data, folderId: folder.id)
        var rule = try #require(result.rules.first { $0.name == "Seen" })
        #expect(rule.conditions.contains { $0.kind == .dateLastOpened && $0.operator == .afterLastModified })
        #expect(rule.conditions.contains { $0.kind == .contentType && $0.value == "public.movie" })
        #expect(rule.actions.count == 1)
        // The stored destination is user-specific; only remap it into the fixture.
        rule.enabled = true
        rule.actions[0].params = .object([ActionParam.destination: .string(destination.path)])
        let preview = source.file("preview.mov")
        let manual = source.file("manual.mov")
        let watched = source.file("watched.mov")
        let unseen = source.file("unseen.mov")
        let metadata = FixtureMetadata()
        for condition in rule.conditions {
            let actual = try URL(fileURLWithPath: preview).resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier ?? "nil"
            #expect(ConditionEvaluator.evaluate(condition, path: preview, depth: 0, lastOpened: metadata), "\(condition.kind) \(condition.operator) \(condition.value), actual=\(actual)")
        }
        #expect(RuleEngine.previewFile(path: preview, depth: 0, rules: [rule], lastOpened: metadata) != nil)
        #expect(RuleEngine.previewFile(path: unseen, depth: 0, rules: [rule], lastOpened: metadata) == nil)
        #expect(RuleEngine.run(path: manual, depth: 0, rules: [rule], batchId: "seen", lastOpened: metadata).history.first?.status == .applied)
        try db.insertRule(rule)
        WatcherCoordinator(db: db, lastOpened: metadata).handle(path: watched)
        #expect(try db.listHistory().first?.status == .applied)
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("manual.mov")))
        #expect(FileManager.default.fileExists(atPath: (destination.path as NSString).appendingPathComponent("watched.mov")))
        #expect(FileManager.default.fileExists(atPath: unseen))
    }
}
