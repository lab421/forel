import Foundation
import CoreServices

/// Supplies the Spotlight last-used date. `nil` means metadata could not be
/// inspected; `.distantPast` represents an item that has never been opened.
public protocol LastOpenedMetadataProvider: Sendable {
    func lastOpened(path: String) -> Date?
}

public struct SpotlightLastOpenedMetadata: LastOpenedMetadataProvider {
    public init() {}
    public func lastOpened(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return (MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date) ?? .distantPast
    }
}
