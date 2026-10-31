// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import Foundation
import Testing
@testable import ForelCore

@Suite struct FileFlagTests {
    @Test func locksAndExtensionVisibilityArePreviewedAppliedAndReverted() throws {
        let dir = TempDir()
        for (kind, key) in [(ActionKind.setLocked, URLResourceKey.isUserImmutableKey), (.setExtensionHidden, .hasHiddenExtensionKey)] {
            let file = dir.file("\(kind.rawValue).txt")
            let url = URL(fileURLWithPath: file)
            defer { try? (url as NSURL).setResourceValue(false, forKey: .isUserImmutableKey) }
            try (url as NSURL).setResourceValue(false, forKey: key)
            func flag() throws -> Bool? {
                let values = try URL(fileURLWithPath: file).resourceValues(forKeys: [key])
                return kind == .setLocked ? values.isUserImmutable : values.hasHiddenExtension
            }
            let action = makeAction(kind, .object([ActionParam.enabled: .bool(true)]))
            #expect(try ActionExecutor.plan(action, path: file).status == .wouldRun)
            #expect(try flag() == false)
            let applied = try ActionExecutor.execute(action, path: file)
            #expect(try flag() == true)
            let roundTrip = Undo.fromJSON(applied.undo.toJSON())
            #expect(roundTrip == applied.undo)
            try ActionExecutor.revert(roundTrip)
            #expect(try flag() == false)
        }
    }
}
