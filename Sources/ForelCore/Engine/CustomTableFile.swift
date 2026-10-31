import Foundation
import Darwin

/// Reads a bounded UTF-8 delimited table without executing or modifying it.
enum CustomTableFile {
    static func read(path: String, separator: String) -> [[String]]? {
        guard separator.count == 1, let delimiter = separator.first, delimiter != "\n", delimiter != "\r", delimiter != "\"" else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0, info.st_size <= 1_000_000 else { return nil }
        var data = Data()
        while data.count <= 1_000_000 {
            do {
                guard let chunk = try handle.read(upToCount: min(64_000, 1_000_001 - data.count)), !chunk.isEmpty else { break }
                data.append(chunk)
            } catch { return nil }
        }
        var after = stat()
        guard data.count <= 1_000_000, fstat(fd, &after) == 0, after.st_size == Int64(data.count),
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text, delimiter: delimiter)
    }

    static func parse(_ text: String, delimiter: Character) -> [[String]]? {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false, closedQuote = false, index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inQuotes {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" { field.append("\""); index = text.index(after: next); continue }
                    inQuotes = false; closedQuote = true
                } else { field.append(character) }
            } else if character == "\"" {
                guard field.isEmpty, !closedQuote else { return nil }
                inQuotes = true
            } else if character == delimiter {
                row.append(field); field = ""; closedQuote = false
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                row.append(field); rows.append(row); row = []; field = ""; closedQuote = false
                if character == "\r", next < text.endIndex, text[next] == "\n" { index = text.index(after: next); continue }
            } else {
                guard !closedQuote else { return nil }
                field.append(character)
            }
            guard field.utf8.count <= 4096, row.count <= 50, rows.count <= 1001 else { return nil }
            index = next
        }
        guard !inQuotes else { return nil }
        if !row.isEmpty || !field.isEmpty || closedQuote { row.append(field); rows.append(row) }
        return rows.count <= 1001 ? rows : nil
    }
}
