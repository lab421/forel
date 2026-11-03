import Foundation
import Darwin

/// Finder's Get Info comment, stored as a property-list string in an xattr.
/// Reading the file directly avoids waiting for Spotlight indexing.
enum FinderComment {
    static let xattrName = "com.apple.metadata:kMDItemFinderComment"

    /// No attribute means an empty comment. Errors or invalid data stay
    /// unknown, so negative conditions cannot match unreadable metadata.
    static func read(_ path: String) -> String? {
        let size = getxattr(path, xattrName, nil, 0, 0, 0)
        if size < 0 { return errno == ENOATTR ? "" : nil }
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let count = getxattr(path, xattrName, &buffer, size, 0, 0)
        guard count > 0 else { return nil }
        let data = Data(buffer.prefix(count))
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return value as? String
    }
}
