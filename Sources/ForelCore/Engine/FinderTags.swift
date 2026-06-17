import Foundation
import Darwin

/// macOS Finder tags via the `com.apple.metadata:_kMDItemUserTags` extended
/// attribute. Tags are stored as a binary-plist-encoded `[String]`. A colour
/// label is just a tag whose name matches a system colour, optionally suffixed
/// with "\nN" (the colour's Finder index).
enum FinderTags {
    static let xattrName = "com.apple.metadata:_kMDItemUserTags"

    /// Reads the Finder tags on `path`, or an empty list if there are none.
    static func read(_ path: String) -> [String] {
        let size = getxattr(path, xattrName, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, xattrName, &buffer, size, 0, 0)
        guard read > 0 else { return [] }
        let data = Data(buffer[0..<read])
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let tags = plist as? [String] else {
            return []
        }
        return tags
    }

    /// Serialises `tags` to a binary plist and writes them to the xattr.
    static func write(_ path: String, _ tags: [String]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        let result = data.withUnsafeBytes { bytes in
            setxattr(path, xattrName, bytes.baseAddress, data.count, 0, 0)
        }
        guard result == 0 else {
            throw SQLiteError("failed to write tags xattr on \(path): errno \(errno)")
        }
    }

    /// Adds or removes a named Finder tag on `path`. Finder reads tags live so
    /// the change is visible immediately without any Finder restart.
    static func apply(_ path: String, tag: String, add: Bool) throws {
        var tags = read(path)
        if add {
            if !tags.contains(tag) { tags.append(tag) }
        } else {
            tags.removeAll { $0 == tag }
        }
        try write(path, tags)
    }

    /// Finder colour-label index for each of the 7 system colours.
    static func colorIndex(_ name: String) -> Int? {
        switch name.lowercased() {
        case "gray", "grey": return 1
        case "green": return 2
        case "purple": return 3
        case "blue": return 4
        case "yellow": return 5
        case "red": return 6
        case "orange": return 7
        default: return nil
        }
    }

    static func currentColorName(_ path: String) -> String {
        for tag in read(path) {
            let name = tag.split(separator: "\n").first.map(String.init) ?? tag
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if colorIndex(trimmed) != nil { return trimmed.lowercased() }
        }
        return ""
    }

    /// Sets the macOS colour label on `path`, replacing any existing colour
    /// label. An empty/unknown colour just clears the label.
    static func setColorLabel(_ path: String, color: String) throws {
        var tags = read(path)
        tags.removeAll { tag in
            let name = tag.split(separator: "\n").first.map(String.init) ?? tag
            return colorIndex(name.trimmingCharacters(in: .whitespaces)) != nil
        }
        if let idx = colorIndex(color) {
            tags.append("\(capitalize(color))\n\(idx)")
        }
        try write(path, tags)
    }

    private static func capitalize(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst().lowercased()
    }
}
