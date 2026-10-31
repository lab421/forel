import Foundation
import Testing
@testable import ForelCore

/// Invoked only by the strict corpus runner's --audit mode. Each JSON line
/// records every imported rule, its blocking omissions and external runtime
/// dependencies; import failures are reported separately and fail the audit.
@Suite struct HazelCorpusAuditTests {
    private struct Manifest: Decodable { let sources: [Source] }
    private struct Source: Decodable { let env: String; let files: [String: String] }

    private func conditionDependencies(_ condition: Condition, level: Int = 0) -> [String] {
        guard level < 16 else { return ["condition nesting exceeds supported depth"] }
        switch condition.kind {
        case .conditionGroup:
            return ConditionGroup.decode(condition.value)?.conditions.flatMap { conditionDependencies($0, level: level + 1) } ?? ["invalid nested condition"]
        case .hazelScriptCondition: return ["condition script interpreter and permissions (also runs in preview)"]
        case .contents: return ["content extraction and, for images/scans, text recognition"]
        case .spotlightAttribute, .dateLastOpened: return ["macOS Spotlight metadata availability"]
        case .currentTime, .dateLastMatched: return ["time-based scheduling and persistent match state"]
        default: return []
        }
    }

    @Test func auditEveryPinnedExport() throws {
        guard ProcessInfo.processInfo.environment["FOREL_HAZEL_AUDIT"] == "1" else { return }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/hazel-corpus-manifest.json")))
        var files = 0, rules = 0, blocked = 0, failures = 0
        var lines: [String] = []
        func emit(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            lines.append(String(decoding: data, as: UTF8.self))
        }
        for source in manifest.sources {
            let root = try #require(ProcessInfo.processInfo.environment[source.env], "Missing required corpus \(source.env)")
            for relative in source.files.keys.sorted() {
                files += 1
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(relative))
                    let result = try RuleTransfer.importRules(from: data, folderId: "audit")
                    for rule in result.rules {
                        rules += 1
                        if rule.importError != nil { blocked += 1 }
                        let dependencies = Array(Set(rule.conditions.flatMap { conditionDependencies($0) } + rule.actions.compactMap { action -> String? in
                            switch action.kind {
                            case .runHazelShellScript, .runScript: return "shell interpreter and script permissions"
                            case .runHazelAppleScript, .runHazelOSA: return "AppleScript/JavaScript runtime and automation permissions"
                            case .runShortcut: return "Shortcuts and configured shortcut"
                            case .openApplication, .openDefault: return "configured application or default handler"
                            case .importToLibrary: return "media library and automation permissions"
                            default: return nil
                            }
                        })).sorted()
                        try emit(["source": source.env, "file": relative, "rule": rule.name,
                                  "blocked": rule.importError != nil, "blockingIssues": rule.importError.map { $0.components(separatedBy: "\n") } ?? [],
                                  "reviewIssues": result.issues.filter { $0.ruleName == rule.name }.map(\.message),
                                  "conditions": rule.conditions.map { $0.kind.rawValue },
                                  "actions": rule.actions.map { $0.kind.rawValue }, "runtimeDependencies": dependencies])
                    }
                } catch {
                    failures += 1
                    try emit(["source": source.env, "file": relative, "importFailure": String(describing: error)])
                }
            }
        }
        try emit(["summary": true, "exports": files, "rules": rules, "blockedRules": blocked, "importFailures": failures])
        if let output = ProcessInfo.processInfo.environment["FOREL_HAZEL_AUDIT_OUTPUT"] {
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: output), options: .atomic)
            print("HAZEL_AUDIT_REPORT \(output)")
        } else {
            for line in lines { print("HAZEL_AUDIT " + line) }
        }
        #expect(failures == 0, "Some pinned exports could not be read or imported")
    }
}
