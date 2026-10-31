// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421

import Foundation
import Testing
@testable import ForelCore

@Suite struct HazelWrappedArchiveTests {
    // Public backup: jaxfry/nixos-configs-mac, hazel-backup/16777230-36143.hazelrules.
    @Test func verifiedPublicBackupImportsAndCorruptionIsRejected() throws {
        guard let root = ProcessInfo.processInfo.environment["FOREL_HAZEL_WRAPPED"] else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent("modules/home/programs/hazel-backup/16777230-36143.hazelrules")
        let data = try Data(contentsOf: url)
        let result = try RuleTransfer.importRules(from: data, folderId: "test")
        #expect(result.rules.map(\.name) == ["FLAC dequarentine", "Subfolder Search"])
        #expect(result.rules.allSatisfy { !$0.enabled && $0.isHazelImported })
        #expect(result.rules[0].actions.map(\.kind) == [.runHazelShellScript])
        #expect(result.rules[0].actions[0].params[ActionParam.shell]?.stringValue == "/bin/zsh")
        #expect(result.rules[0].actions[0].params[ActionParam.script]?.stringValue == "xattr -dr com.apple.quarantine \"$1\"")
        #expect(result.rules[1].actions.map(\.kind) == [.hazelRecurse])
        #expect(result.rules.allSatisfy { $0.importError == nil })
        var corrupt = data
        corrupt[corrupt.startIndex + 8] ^= 1
        #expect(throws: RuleTransferError.self) { try RuleTransfer.importRules(from: corrupt, folderId: "test") }
        var unknownVersion = data
        unknownVersion[unknownVersion.startIndex + 7] = 28
        #expect(throws: RuleTransferError.self) { try RuleTransfer.importRules(from: unknownVersion, folderId: "test") }
    }
}
