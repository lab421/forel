// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import Darwin

/// macOS Finder tags via the `com.apple.metadata:_kMDItemUserTags` extended
/// attribute. Tags are stored as a binary-plist-encoded `[String]`. A colour
/// label is just a tag whose name matches a system colour, optionally suffixed
/// with "\nN" (the colour's Finder index).
enum FinderTags {
    static let xattrName = "com.apple.metadata:_kMDItemUserTags"

    /// Unlike `read`, distinguish missing tags from an unreadable or malformed
    /// attribute when deciding whether an imported label is safe.
    static func hasExistingTags(_ path: String) throws -> Bool {
        return try readChecked(path).isEmpty == false
    }

    static func readChecked(_ path: String) throws -> [String] {
        let size = getxattr(path, xattrName, nil, 0, 0, 0)
        if size < 0 {
            if errno == ENOATTR { return [] }
            throw ActionError("Cannot inspect Finder tags (errno \(errno))")
        }
        guard size > 0 else { throw ActionError("Cannot read Finder tags") }
        var bytes = [UInt8](repeating: 0, count: size)
        let count = getxattr(path, xattrName, &bytes, size, 0, 0)
        guard count == size,
              let tags = (try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)) as? [String] else {
            throw ActionError("Cannot read Finder tags")
        }
        return tags
    }

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
            if let index = tagColor(tag) { return colorName(index) ?? "" }
        }
        return ""
    }

    /// Sets the macOS colour label on `path`, replacing any existing colour
    /// label. An empty/unknown colour just clears the label.
    static func setColorLabel(_ path: String, color: String) throws {
        var tags = try readChecked(path)
        let target = colorIndex(color)
        tags.removeAll { tagColor($0).map { $0 != target } ?? false }
        if let idx = target, !tags.contains(where: { tagColor($0) == idx }) {
            tags.append("\(capitalize(color))\n\(idx)")
        }
        try write(path, tags)
    }

    static func tagColor(_ tag: String) -> Int? {
        guard let separator = tag.lastIndex(of: "\n"),
              let value = Int(tag[tag.index(after: separator)...]), (1...7).contains(value) else { return nil }
        return value
    }

    static func colorName(_ index: Int) -> String? {
        [1: "gray", 2: "green", 3: "purple", 4: "blue", 5: "yellow", 6: "red", 7: "orange"][index]
    }

    static func restoreColors(_ path: String, before: [String], after: [String]) throws {
        let tags = try readChecked(path)
        guard tags.filter({ tagColor($0) != nil }) == after else {
            throw ActionError("Finder color tags changed since this action ran")
        }
        try write(path, tags.filter { tagColor($0) == nil } + before)
    }

    private static func capitalize(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst().lowercased()
    }
}
