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

/// Paths on disks and network shares mounted under /Volumes.
///
/// A network share picked through "Network" in the folder picker is mounted
/// a second time when it is already connected; the name being taken, macOS
/// mounts it at `/Volumes/<name>-1`. That second mount goes away later, and a
/// rule pointing at it then fails with an error about the startup disk.
public enum VolumePaths {
    public struct Mount: Sendable, Equatable {
        /// Where the volume is mounted, e.g. `/Volumes/SG_Shared`.
        public let mountPoint: String
        /// What is mounted, e.g. `//fred@nas.local/SG_Shared` or `/dev/disk4s1`.
        public let source: String
        /// The file system type, e.g. `smbfs`, `apfs`, `autofs`.
        public let fileSystem: String

        public init(mountPoint: String, source: String, fileSystem: String = "") {
            self.mountPoint = mountPoint
            self.source = source
            self.fileSystem = fileSystem
        }
    }

    /// The mount table, read the way `mount` does. `getmntinfo` reuses one
    /// shared buffer and isn't thread-safe; rules run off the main thread,
    /// so each call gets its own buffer.
    public static func currentMounts() -> [Mount] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        defer { free(buffer) }
        return (0..<Int(count)).map { index in
            var entry = buffer[index]
            return Mount(
                mountPoint: cString(&entry.f_mntonname),
                source: cString(&entry.f_mntfromname),
                fileSystem: cString(&entry.f_fstypename)
            )
        }
    }

    /// `path` moved onto the first mount of its volume when it was picked
    /// through a duplicate mount (`/Volumes/<name>-<n>`). Both mounts must be
    /// proven to be the same volume, whatever the protocol: a trailing number
    /// alone proves nothing, as a second disk also named "Backup" is mounted
    /// as "Backup-1".
    public static func canonical(
        _ path: String,
        mounts: [Mount] = currentMounts(),
        remountURL: (String) -> URL? = remountURL(ofVolumeAt:),
        identity: (String) -> ItemIdentity? = itemIdentity(atPath:)
    ) -> String {
        let standardized = (path as NSString).standardizingPath
        // Automount triggers aren't volumes, and they all share sources like
        // "map -fstab": comparing them would mistake one share for another.
        let mounts = mounts.filter { $0.fileSystem != "autofs" }
        guard let picked = mount(containing: standardized, in: mounts),
              let suffix = picked.mountPoint.range(of: #"-\d+$"#, options: .regularExpression)
        else { return path }
        let originalMountPoint = String(picked.mountPoint[..<suffix.lowerBound])
        let relativePath = String(standardized.dropFirst(picked.mountPoint.count))
        guard let original = mounts.first(where: { $0.mountPoint == originalMountPoint }),
              sameVolume(original, picked, relativePath: relativePath, remountURL: remountURL, identity: identity)
        else { return path }
        return originalMountPoint + relativePath
    }

    /// What tells one file or folder apart, as seen through any mount of its
    /// volume: the file ID the server reports, and when it was created.
    public struct ItemIdentity: Sendable, Equatable {
        public let fileId: UInt64
        public let created: Double

        public init(fileId: UInt64, created: Double) {
            self.fileId = fileId
            self.created = created
        }
    }

    public static func itemIdentity(atPath path: String) -> ItemIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let created = Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000
        // Without a creation date, a file ID alone may just be derived from
        // the path, and would match on any server.
        guard created > 0 else { return nil }
        return ItemIdentity(fileId: UInt64(info.st_ino), created: created)
    }

    /// The URL macOS would use to mount this network volume again
    /// (`smb://`, `afp://`, `nfs://`, WebDAV…), nil for a local disk.
    public static func remountURL(ofVolumeAt mountPoint: String) -> URL? {
        try? URL(fileURLWithPath: mountPoint, isDirectory: true)
            .resourceValues(forKeys: [.volumeURLForRemountingKey])
            .volumeURLForRemounting
    }

    /// The name of the /Volumes entry `path` lives under when nothing is
    /// mounted there and it can't be written to: the disk or share it was
    /// chosen on isn't connected.
    public static func unmountedVolume(
        of path: String,
        mounts: [Mount] = currentMounts(),
        fileManager: FileManager = .default
    ) -> String? {
        let components = ((path as NSString).standardizingPath as NSString).pathComponents
        guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else { return nil }
        let entry = "/Volumes/\(components[2])"
        if mounts.contains(where: { $0.mountPoint == entry }) { return nil }
        // A link, like /Volumes/Macintosh HD pointing at /, leads elsewhere.
        if (try? fileManager.destinationOfSymbolicLink(atPath: entry)) != nil { return nil }
        if fileManager.isWritableFile(atPath: entry) { return nil }
        return components[2]
    }

    /// The innermost /Volumes mount holding `path`.
    private static func mount(containing path: String, in mounts: [Mount]) -> Mount? {
        mounts
            .filter { $0.mountPoint.hasPrefix("/Volumes/") }
            .filter { path == $0.mountPoint || path.hasPrefix($0.mountPoint + "/") }
            .max { $0.mountPoint.count < $1.mountPoint.count }
    }

    /// Two mounts of one volume. Network volumes are compared by the location
    /// macOS remounts them from, which every protocol provides; otherwise by
    /// what the mount table says is mounted.
    private static func sameVolume(
        _ lhs: Mount,
        _ rhs: Mount,
        relativePath: String,
        remountURL: (String) -> URL?,
        identity: (String) -> ItemIdentity?
    ) -> Bool {
        guard let lhsURL = remountURL(lhs.mountPoint), let rhsURL = remountURL(rhs.mountPoint) else {
            return sameSource(lhs.source, rhs.source)
        }
        guard sameShare(lhsURL, rhsURL) else { return false }
        if sameServer(lhsURL, rhsURL) { return true }
        // One server reached under two names, e.g. its Bonjour service from
        // the "Network" sidebar and its host name or IP address: no ID tells
        // the server apart (Apple DTS), so the folder itself must be the same
        // on both sides, and so must the share's root.
        return [relativePath, ""].allSatisfy { item in
            guard let left = identity(lhs.mountPoint + item),
                  let right = identity(rhs.mountPoint + item)
            else { return false }
            return left == right
        }
    }

    /// Same protocol and share: `smb://fred@nas.local/Share` and
    /// `smb://guest@NAS.local/share`. SMB and AFP names ignore case; other
    /// paths don't.
    private static func sameShare(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let scheme = lhs.scheme?.lowercased(), scheme == rhs.scheme?.lowercased() else { return false }
        func location(_ url: URL) -> String {
            let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
            return ["smb", "cifs", "afp"].contains(scheme) ? path.lowercased() : path
        }
        return location(lhs) == location(rhs)
    }

    /// Same server and port, whoever is signed in.
    private static func sameServer(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let host = lhs.host?.lowercased(), host == rhs.host?.lowercased() else { return false }
        return lhs.port == rhs.port
    }

    /// Same entry in the mount table. SMB sources (`//fred@nas.local/Share`)
    /// are compared without the user and case; any other source as is.
    private static func sameSource(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ source: String) -> String {
            guard source.hasPrefix("//") else { return source }
            var rest = source.dropFirst(2)
            if let at = rest.firstIndex(of: "@"), at < (rest.firstIndex(of: "/") ?? rest.endIndex) {
                rest = rest[rest.index(after: at)...]
            }
            return "//" + rest.lowercased()
        }
        return normalized(lhs) == normalized(rhs)
    }

    /// A NUL-terminated `statfs` name. One that isn't valid UTF-8 comes back
    /// empty, which matches no path.
    private static func cString<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
    }
}
