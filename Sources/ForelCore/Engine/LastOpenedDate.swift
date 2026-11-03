import Foundation
import Darwin

enum LastOpenedDate {
    /// LaunchServices records this timespec (two little-endian 64-bit values)
    /// on the item. Read it directly so recent opens are visible without
    /// waiting for Spotlight, including on volumes that are not indexed.
    static let xattrName = "com.apple.lastuseddate#PS"

    static func read(_ path: String) -> Date? {
        let capacity = 16
        var bytes = [UInt8](repeating: 0, count: capacity)
        let count = getxattr(path, xattrName, &bytes, capacity, 0, 0)
        // Missing, unreadable, or malformed dates stay unknown. Do not
        // substitute an access/creation date or an inferred indexed value.
        guard count == capacity else { return nil }
        let seconds = bytes.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
        let nanoseconds = bytes.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: Int64.self)) }
        guard seconds > 0, (0..<1_000_000_000).contains(nanoseconds) else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }
}
