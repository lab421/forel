import Foundation
import Testing
@testable import ForelCore

@Suite struct TestingTrashTests {
    @Test func explicitTestTrashAcceptsOnlyRealScopedDirectory() throws {
        #if DEBUG
        let base = "/tmp/forel-hazel-trash-test-\(UUID().uuidString)"
        let directory = (base as NSString).appendingPathComponent("trash")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let resolved = try TestingTrash.validate(directory)
        #expect(resolved.hasPrefix("/private/tmp/forel-hazel-trash-test-"))
        #expect(throws: ActionError.self) { try TestingTrash.validate("/tmp") }
        #expect(throws: ActionError.self) { try TestingTrash.validate("relative") }
        let link = (base as NSString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory)
        #expect(throws: ActionError.self) { try TestingTrash.validate(link) }
        let source = (base as NSString).appendingPathComponent("fixture.txt")
        try "fixture".write(toFile: source, atomically: true, encoding: .utf8)
        let moved = try TestingTrash.move(source, into: resolved)
        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(try String(contentsOfFile: moved, encoding: .utf8) == "fixture")
        #endif
    }
}
