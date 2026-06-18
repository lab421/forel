import Foundation
import Darwin

/// Reads macOS download-origin metadata — the same data Finder's Get Info
/// panel shows as "Where from". Backs the `downloaded_from_website`,
/// `downloaded_with_app`, and `raw_where_from_metadata` conditions.
public enum DownloadMetadata {
    private static let whereFromsAttr = "com.apple.metadata:kMDItemWhereFroms"
    private static let quarantineAttr = "com.apple.quarantine"

    /// Every string value stored in `kMDItemWhereFroms`, in their original
    /// order. Empty if the attribute is absent, unreadable, not a valid
    /// plist, not an array, or contains no string values.
    public static func whereFroms(_ path: String) -> [String] {
        guard let data = readXattr(path, name: whereFromsAttr) else { return [] }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return []
        }
        guard let array = plist as? [Any] else { return [] }
        return array.compactMap { $0 as? String }
    }

    /// The subset of `whereFroms` that look like web URLs.
    public static func websiteURLs(_ path: String) -> [String] {
        whereFroms(path).filter {
            let lowered = $0.lowercased()
            return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
        }
    }

    /// The app responsible for downloading the file, if macOS recorded one.
    ///
    /// Deliberately conservative: this reads only the agent-name field of the
    /// `com.apple.quarantine` extended attribute — the same value Gatekeeper
    /// uses for "downloaded from the internet" warnings, written by the
    /// downloading app itself, not inferred. There's no fallback that guesses
    /// an app from `kMDItemWhereFroms` text or the file's folder: if the
    /// quarantine attribute is missing, malformed, or has an empty agent
    /// field (e.g. the file was never quarantined, or was created locally),
    /// this returns `nil` rather than a guess.
    public static func downloadedWithApp(_ path: String) -> String? {
        guard let data = readXattr(path, name: quarantineAttr),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        // Format: "<flags>;<timestamp-hex>;<agent name>;<event UUID>".
        let fields = raw.split(separator: ";", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3 else { return nil }
        let agent = (fields[2].removingPercentEncoding ?? fields[2]).trimmingCharacters(in: .whitespaces)
        return agent.isEmpty ? nil : agent
    }

    private static func readXattr(_ path: String, name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        return Data(buffer[0..<read])
    }
}
