// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import Foundation
import Darwin

enum FinderComment {
    private static let key = "com.apple.metadata:kMDItemFinderComment"

    static func read(_ path: String) throws -> String? {
        let size = getxattr(path, key, nil, 0, 0, 0)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw ActionError("Cannot read Finder comment (errno \(errno))")
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let count = getxattr(path, key, &bytes, size, 0, 0)
        guard count == size,
              let value = try PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil) as? String else {
            throw ActionError("Cannot decode Finder comment")
        }
        return value
    }

    static func write(_ path: String, value: String?) throws {
        guard let value else {
            if removexattr(path, key, 0) != 0 && errno != ENOATTR {
                throw ActionError("Cannot remove Finder comment (errno \(errno))")
            }
            return
        }
        let bytes = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        guard bytes.withUnsafeBytes({ setxattr(path, key, $0.baseAddress, bytes.count, 0, 0) }) == 0 else {
            throw ActionError("Cannot write Finder comment (errno \(errno))")
        }
    }
}
