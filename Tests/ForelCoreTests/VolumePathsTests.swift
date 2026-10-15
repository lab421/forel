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

import Testing
import Foundation
@testable import ForelCore

@Suite struct VolumePathsTests {
    private let boot = VolumePaths.Mount(mountPoint: "/", source: "/dev/disk3s1s1")
    private let share = VolumePaths.Mount(mountPoint: "/Volumes/SG_Shared", source: "//fred@nas.local/SG_Shared")

    @Test func folderPickedThroughASecondMountOfTheSameShareUsesTheFirstMount() {
        // Browsing "Network" in the folder picker mounts the share again; the
        // name being taken, macOS mounts it at SG_Shared-1, which goes away later.
        let duplicate = VolumePaths.Mount(mountPoint: "/Volumes/SG_Shared-1", source: "//guest@NAS.local/SG_Shared")
        let mounts = [boot, share, duplicate]

        #expect(VolumePaths.canonical("/Volumes/SG_Shared-1/Paperless/Credit Cards/Statements", mounts: mounts)
            == "/Volumes/SG_Shared/Paperless/Credit Cards/Statements")
        #expect(VolumePaths.canonical("/Volumes/SG_Shared-1", mounts: mounts) == "/Volumes/SG_Shared")
    }

    @Test func pathIsKeptWhenTheSuffixedVolumeIsADifferentShare() {
        // Same share name on another server, or on a host macOS reached under
        // another name: nothing proves it's the same folder, so nothing changes.
        let otherServer = VolumePaths.Mount(mountPoint: "/Volumes/SG_Shared-1", source: "//fred@backup.local/SG_Shared")
        #expect(VolumePaths.canonical("/Volumes/SG_Shared-1/Paperless", mounts: [boot, share, otherServer])
            == "/Volumes/SG_Shared-1/Paperless")
    }

    @Test func pathIsKeptWhenOnlyTheSuffixedMountExists() {
        let only = VolumePaths.Mount(mountPoint: "/Volumes/SG_Shared-1", source: "//fred@nas.local/SG_Shared")
        #expect(VolumePaths.canonical("/Volumes/SG_Shared-1/Paperless", mounts: [boot, only])
            == "/Volumes/SG_Shared-1/Paperless")
    }

    @Test func volumeWhoseNameEndsWithANumberIsNotTreatedAsADuplicate() {
        let backup1 = VolumePaths.Mount(mountPoint: "/Volumes/Backup-1", source: "/dev/disk5s1")
        let backup = VolumePaths.Mount(mountPoint: "/Volumes/Backup", source: "/dev/disk4s1")
        #expect(VolumePaths.canonical("/Volumes/Backup-1/Photos", mounts: [boot, backup, backup1])
            == "/Volumes/Backup-1/Photos")
    }

    @Test func pathsOutsideVolumesAreUnchanged() {
        #expect(VolumePaths.canonical("/Users/fred/Documents", mounts: [boot, share]) == "/Users/fred/Documents")
    }

    @Test func missingVolumeIsReportedByName() {
        let mounts = [boot, share]
        #expect(VolumePaths.unmountedVolume(of: "/Volumes/SG_Shared-1/Paperless", mounts: mounts) == "SG_Shared-1")
        #expect(VolumePaths.unmountedVolume(of: "/Volumes/SG_Shared/Paperless", mounts: mounts) == nil)
        #expect(VolumePaths.unmountedVolume(of: "/Users/fred/Documents", mounts: mounts) == nil)
    }

    @Test func duplicateMountIsRecognisedWhateverTheProtocol() {
        // AFP mount sources are random per mount ("afp_…"): only the remount
        // URL shows both are the same share, signed in as different users.
        let afpOriginal = VolumePaths.Mount(mountPoint: "/Volumes/Archive", source: "afp_0TQC3q2r5RSB0LVJbz-1.2d000005", fileSystem: "afpfs")
        let afpDuplicate = VolumePaths.Mount(mountPoint: "/Volumes/Archive-1", source: "afp_1yNhUo0Qnb4E3LkTbn-2.2d000006", fileSystem: "afpfs")
        let remount: (String) -> URL? = { mountPoint in
            [
                "/Volumes/Archive": URL(string: "afp://fred@NAS.local/Archive/"),
                "/Volumes/Archive-1": URL(string: "afp://guest@nas.local/archive"),
            ][mountPoint] ?? nil
        }
        #expect(VolumePaths.canonical("/Volumes/Archive-1/2026", mounts: [boot, afpOriginal, afpDuplicate], remountURL: remount)
            == "/Volumes/Archive/2026")

        // NFS: the same export appears with the same source.
        let nfsOriginal = VolumePaths.Mount(mountPoint: "/Volumes/media", source: "nas.local:/volume1/media", fileSystem: "nfs")
        let nfsDuplicate = VolumePaths.Mount(mountPoint: "/Volumes/media-2", source: "nas.local:/volume1/media", fileSystem: "nfs")
        #expect(VolumePaths.canonical("/Volumes/media-2/Movies", mounts: [boot, nfsOriginal, nfsDuplicate], remountURL: { _ in nil })
            == "/Volumes/media/Movies")
    }

    @Test func differentNetworkLocationsAreNeverMerged() {
        let original = VolumePaths.Mount(mountPoint: "/Volumes/Share", source: "//fred@nas.local/Share", fileSystem: "smbfs")
        let duplicate = VolumePaths.Mount(mountPoint: "/Volumes/Share-1", source: "//fred@nas.local/Share", fileSystem: "smbfs")
        let mounts = [boot, original, duplicate]
        // The remount URL decides when both have one: another server, port or
        // protocol is another volume, even with a matching mount table entry.
        for other in ["smb://fred@backup.local/Share", "smb://fred@nas.local:8445/Share", "afp://fred@nas.local/Share", "smb://fred@nas.local/Other"] {
            let remount: (String) -> URL? = { $0 == "/Volumes/Share" ? URL(string: "smb://fred@nas.local/Share") : URL(string: other) }
            #expect(VolumePaths.canonical("/Volumes/Share-1/Docs", mounts: mounts, remountURL: remount) == "/Volumes/Share-1/Docs")
        }
        // NFS paths are case sensitive: these are two exports.
        let upper = VolumePaths.Mount(mountPoint: "/Volumes/Media", source: "nas.local:/Media", fileSystem: "nfs")
        let lower = VolumePaths.Mount(mountPoint: "/Volumes/Media-1", source: "nas.local:/media", fileSystem: "nfs")
        let nfsRemount: (String) -> URL? = { $0 == "/Volumes/Media" ? URL(string: "nfs://nas.local/Media") : URL(string: "nfs://nas.local/media") }
        #expect(VolumePaths.canonical("/Volumes/Media-1/x", mounts: [boot, upper, lower], remountURL: nfsRemount) == "/Volumes/Media-1/x")
    }

    @Test func oneServerReachedUnderTwoNamesNeedsTheSameFolderOnBothSides() {
        // The "Network" sidebar reaches the NAS through its Bonjour service;
        // the share connected at login used its IP address.
        let original = VolumePaths.Mount(mountPoint: "/Volumes/SG_Shared", source: "//fred@192.168.1.20/SG_Shared", fileSystem: "smbfs")
        let duplicate = VolumePaths.Mount(mountPoint: "/Volumes/SG_Shared-1", source: "//fred@SG-NAS._smb._tcp.local/SG_Shared", fileSystem: "smbfs")
        let mounts = [boot, original, duplicate]
        let remount: (String) -> URL? = {
            $0 == "/Volumes/SG_Shared" ? URL(string: "smb://fred@192.168.1.20/SG_Shared") : URL(string: "smb://fred@SG-NAS._smb._tcp.local/SG_Shared")
        }
        let picked = "/Volumes/SG_Shared-1/Paperless/Credit Cards/Statements"
        let root = VolumePaths.ItemIdentity(fileId: 2, created: 1_700_000_000.25)
        let folder = VolumePaths.ItemIdentity(fileId: 81_234, created: 1_750_000_000.5)

        func identity(original: VolumePaths.ItemIdentity?, duplicate: VolumePaths.ItemIdentity?, rootMatches: Bool = true) -> (String) -> VolumePaths.ItemIdentity? {
            { path in
                switch path {
                case "/Volumes/SG_Shared": return root
                case "/Volumes/SG_Shared-1": return rootMatches ? root : VolumePaths.ItemIdentity(fileId: 2, created: 1_600_000_000)
                case "/Volumes/SG_Shared/Paperless/Credit Cards/Statements": return original
                case picked: return duplicate
                default: return nil
                }
            }
        }

        #expect(VolumePaths.canonical(picked, mounts: mounts, remountURL: remount, identity: identity(original: folder, duplicate: folder))
            == "/Volumes/SG_Shared/Paperless/Credit Cards/Statements")
        // Anything short of proof keeps the picked path.
        let otherFolder = VolumePaths.ItemIdentity(fileId: 81_234, created: 1_750_000_999)
        #expect(VolumePaths.canonical(picked, mounts: mounts, remountURL: remount, identity: identity(original: otherFolder, duplicate: folder)) == picked)
        #expect(VolumePaths.canonical(picked, mounts: mounts, remountURL: remount, identity: identity(original: nil, duplicate: folder)) == picked)
        #expect(VolumePaths.canonical(picked, mounts: mounts, remountURL: remount, identity: identity(original: folder, duplicate: folder, rootMatches: false)) == picked)
        // Another share name is never merged, even with matching IDs.
        let otherShare: (String) -> URL? = {
            $0 == "/Volumes/SG_Shared" ? URL(string: "smb://fred@192.168.1.20/Other") : URL(string: "smb://fred@SG-NAS._smb._tcp.local/SG_Shared")
        }
        #expect(VolumePaths.canonical(picked, mounts: mounts, remountURL: otherShare, identity: identity(original: folder, duplicate: folder)) == picked)
    }

    @Test func itemIdentityIsReadFromTheFileSystem() throws {
        let dir = TempDir()
        let folder = dir.dir("Statements")
        let identity = try #require(VolumePaths.itemIdentity(atPath: folder))
        #expect(VolumePaths.itemIdentity(atPath: folder) == identity)
        #expect(VolumePaths.itemIdentity(atPath: dir.dir("Other")) != identity)
        #expect(VolumePaths.itemIdentity(atPath: folder + "/missing") == nil)
    }

    @Test func automountTriggersAreNeverTakenForTheSameVolume() {
        // Every fstab automount has the source "map -fstab".
        let first = VolumePaths.Mount(mountPoint: "/Volumes/Data", source: "map -fstab", fileSystem: "autofs")
        let second = VolumePaths.Mount(mountPoint: "/Volumes/Data-1", source: "map -fstab", fileSystem: "autofs")
        #expect(VolumePaths.canonical("/Volumes/Data-1/x", mounts: [boot, first, second], remountURL: { _ in nil }) == "/Volumes/Data-1/x")
    }

    @Test func remountURLIsNilForTheStartupDisk() {
        #expect(VolumePaths.remountURL(ofVolumeAt: "/") == nil)
    }

    @Test func innermostMountIsUsedAndTrailingSlashIsIgnored() {
        let duplicate = VolumePaths.Mount(mountPoint: "/Volumes/SG_Shared-1", source: "//fred@nas.local/SG_Shared")
        // A disk mounted inside the share: its path must not be rewritten.
        let nested = VolumePaths.Mount(mountPoint: "/Volumes/SG_Shared-1/Disk", source: "/dev/disk6s1")
        let mounts = [boot, share, duplicate, nested]

        #expect(VolumePaths.canonical("/Volumes/SG_Shared-1/Disk/Photos", mounts: mounts) == "/Volumes/SG_Shared-1/Disk/Photos")
        #expect(VolumePaths.canonical("/Volumes/SG_Shared-1/Paperless/", mounts: mounts) == "/Volumes/SG_Shared/Paperless")
    }

    @Test func writableOrLinkedVolumesEntryIsNotReportedAsDisconnected() {
        // Whatever can still be written to keeps working as before.
        let writable = StubFileManager(writable: true, link: nil)
        let linked = StubFileManager(writable: false, link: "/Users/fred/Shared")
        #expect(VolumePaths.unmountedVolume(of: "/Volumes/Inbox/2026", mounts: [boot], fileManager: writable) == nil)
        #expect(VolumePaths.unmountedVolume(of: "/Volumes/Inbox/2026", mounts: [boot], fileManager: linked) == nil)
        #expect(VolumePaths.unmountedVolume(of: "/Volumes/Inbox/2026", mounts: [boot], fileManager: StubFileManager(writable: false, link: nil)) == "Inbox")
    }

    @Test func moveToAConnectedVolumesPathStillWorks() throws {
        // /Volumes/Macintosh HD leads to the startup disk, which is connected:
        // a destination written through it must be moved into as before.
        let link = "/Volumes/Macintosh HD"
        try #require(FileManager.default.fileExists(atPath: link))
        let dir = TempDir()
        let file = dir.file("report.pdf", contents: "done")
        let realDestination = (dir.path as NSString).appendingPathComponent("Archive/2026")
        let resolvedDestination = URL(fileURLWithPath: realDestination).resolvingSymlinksInPath().path
        let destination = link + resolvedDestination
        let action = makeAction(.moveToFolder, .object([ActionParam.destination: .string(destination)]))

        #expect(try ActionExecutor.plan(action, path: file).warning == nil)
        let applied = try ActionExecutor.execute(action, path: file)

        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: applied.newPath))
        #expect(FileManager.default.fileExists(atPath: (resolvedDestination as NSString).appendingPathComponent("report.pdf")))
    }

    @Test func startupDiskLinkInVolumesCountsAsConnected() throws {
        // /Volumes/Macintosh HD is a link to /, not a mount point of its own.
        let link = "/Volumes/Macintosh HD"
        try #require(FileManager.default.fileExists(atPath: link))
        #expect(VolumePaths.unmountedVolume(of: "\(link)/Users", mounts: [boot]) == nil)
    }

    @Test func currentMountsIncludeTheStartupDisk() {
        #expect(VolumePaths.currentMounts().contains { $0.mountPoint == "/" })
    }
}

/// Answers the two questions `unmountedVolume` asks about a /Volumes entry.
private final class StubFileManager: FileManager, @unchecked Sendable {
    private let writable: Bool
    private let link: String?

    init(writable: Bool, link: String?) {
        self.writable = writable
        self.link = link
        super.init()
    }

    override func isWritableFile(atPath path: String) -> Bool { writable }

    override func destinationOfSymbolicLink(atPath path: String) throws -> String {
        guard let link else { throw CocoaError(.fileReadNoSuchFile) }
        return link
    }
}
