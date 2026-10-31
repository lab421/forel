import Foundation
import Testing
@testable import ForelCore

@Suite struct CustomTableFileTests {
    @Test func parsesDelimitedFilesAndRejectsMalformedRows() throws {
        let dir = TempDir()
        let path = dir.file("table.csv", contents: "Name,ID\r\n\"Ada, A\",42\r\n\"Grace \"\"Amazing\"\"\",73\r\n")
        #expect(CustomTableFile.read(path: path, separator: ",") == [["Name", "ID"], ["Ada, A", "42"], ["Grace \"Amazing\"", "73"]])
        #expect(CustomTableFile.parse("\"unfinished", delimiter: ",") == nil)
        #expect(CustomTableFile.parse("\"quoted\"suffix", delimiter: ",") == nil)
        #expect(CustomTableFile.read(path: path, separator: "") == nil)
    }
    @Test func fileBackedTableUsesCurrentRowsAndFailsClosed() throws {
        let dir = TempDir()
        let path = dir.file("table.csv", contents: "Name,ID\nAda,42\n")
        let target = dir.file("Ada.txt")
        var table = CustomTableCondition(); table.prefix = "People"; table.matchColumn = "Name"; table.filePath = path; table.separator = ","
        #expect(table.evaluate(path: target)?.1["People.ID"] == .string("42"))
        try "Name,ID\nAda,73\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(table.evaluate(path: target)?.1["People.ID"] == .string("73"))
        var reads = 0
        let result = table.evaluate(path: target, loadRows: {
            reads += 1
            return reads == 1 ? [["Name", "ID"], ["Ada", "42"]] : [["Name", "Name"], ["Ada"]]
        })
        #expect(reads == 1)
        #expect(result?.1["People.ID"] == .string("42"))
        try "Name,ID\nAda\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(table.evaluate(path: target) == nil)
    }
}
