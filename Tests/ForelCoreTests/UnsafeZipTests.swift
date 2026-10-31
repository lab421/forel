import Foundation
import Testing
import ZIPFoundation
@testable import ForelCore

@Suite struct UnsafeZipTests {
    @Test(arguments: ["../escape.txt", "folder/../../escape.txt", "/absolute.txt"])
    func rejectsTraversal(entry: String) throws {
        let dir = TempDir()
        let path = (dir.path as NSString).appendingPathComponent("unsafe.zip")
        let zip = try Archive(url: URL(fileURLWithPath: path), accessMode: .create)
        try zip.addEntry(with: entry, type: .file, uncompressedSize: Int64(1), provider: { _, _ in Data([65]) })
        let action = makeAction(.uncompress, .object([:]))
        #expect(throws: ActionError.self) { try ActionExecutor.plan(action, path: path) }
        #expect(throws: ActionError.self) { try ActionExecutor.execute(action, path: path) }
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func rejectsSymbolicLinks() throws {
        let dir = TempDir()
        let path = (dir.path as NSString).appendingPathComponent("unsafe.zip")
        let zip = try Archive(url: URL(fileURLWithPath: path), accessMode: .create)
        let payload = Data("../outside".utf8)
        try zip.addEntry(with: "link", type: .symlink, uncompressedSize: Int64(payload.count)) { _, _ in payload }
        #expect(throws: ActionError.self) { try ActionExecutor.plan(makeAction(.uncompress, .object([:])), path: path) }
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
