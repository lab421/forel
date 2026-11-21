import Foundation

/// Mounts a disk image read-only, copies the applications at its top level
/// into a folder, and unmounts it again. Used by the "Install disk image"
/// action.
enum DiskImageInstaller {
    /// Formats `hdiutil` can attach. Bundle-style `.sparsebundle` images are
    /// directories and are left out.
    static let supportedExtensions: Set<String> = ["dmg", "iso", "img", "sparseimage"]

    /// Prefix of the hidden copies made beside the installed apps before they
    /// take their place. `SystemFileFilter` ignores it so a watched install
    /// folder never acts on a half-written copy.
    static let stagingPrefix = ".forel-install-"

    static func isSupported(_ path: String) -> Bool {
        supportedExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Moves `path` to the Trash and returns where it ended up, or nil if
    /// that is unknown.
    static func trash(_ path: String) throws -> String? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
    }

    /// Copies `source` to `destination`. `ditto` keeps code signatures and
    /// resource forks, which a plain copy can drop.
    static func dittoCopy(_ source: String, _ destination: String) throws {
        let result = try run("/usr/bin/ditto", [source, destination])
        guard result.status == 0 else { throw ActionError(result.error) }
    }

    /// Copies every top-level `.app` into `destinationDir` and returns the
    /// installed paths. Without `replaceExisting`, nothing is copied if any
    /// app already exists there. With it, each new copy is made beside the
    /// old app first, and only then does it take the old app's place. The
    /// old app goes to the Trash, so it can still be restored.
    /// All or nothing: if any copy or replacement fails, apps already swapped
    /// in are removed, the old ones are brought back from the Trash, and no
    /// partial copy is left behind.
    /// The image is always unmounted before this returns.
    static func install(
        imagePath: String,
        into destinationDir: String,
        replaceExisting: Bool = false,
        copyApp: (String, String) throws -> Void = dittoCopy,
        moveToTrash: (String) throws -> String? = trash
    ) throws -> [String] {
        let mountPoint = try attach(imagePath)
        defer { detach(mountPoint) }

        let fm = FileManager.default
        let apps = try fm.contentsOfDirectory(atPath: mountPoint)
            .filter { $0.lowercased().hasSuffix(".app") }
            .sorted()
        guard !apps.isEmpty else {
            throw ActionError("No application was found in this disk image.")
        }

        let targets = apps.map { (destinationDir as NSString).appendingPathComponent($0) }
        let existing = zip(apps, targets).filter { fm.fileExists(atPath: $0.1) }
        if !replaceExisting, let first = existing.first {
            throw ActionError("\(first.0) is already in \(destinationDir), so nothing was installed. Turn on Replace existing app to update it, or remove it first.")
        }

        try fm.createDirectory(atPath: destinationDir, withIntermediateDirectories: true)
        // Copies that have not been moved into place yet. A copy is recorded
        // before it starts, so even one that fails halfway is removed when
        // this function exits.
        var staged: [String] = []
        defer { for copy in staged { try? fm.removeItem(atPath: copy) } }
        for app in apps {
            let source = (mountPoint as NSString).appendingPathComponent(app)
            let copy = (destinationDir as NSString).appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)-\(app)")
            staged.append(copy)
            do {
                try copyApp(source, copy)
            } catch {
                throw ActionError("Could not copy \(app) to \(destinationDir), so nothing was installed. \(message(of: error))")
            }
        }

        var installed: [String] = []
        var replaced: [(original: String, inTrash: String?)] = []
        for (index, (copy, target)) in zip(staged, targets).enumerated() {
            do {
                if fm.fileExists(atPath: target) {
                    replaced.append((target, try moveToTrash(target)))
                }
                try fm.moveItem(atPath: copy, toPath: target)
                installed.append(target)
            } catch {
                for app in installed.reversed() { try? fm.removeItem(atPath: app) }
                for old in replaced.reversed() {
                    if let inTrash = old.inTrash { try? fm.moveItem(atPath: inTrash, toPath: old.original) }
                }
                throw ActionError("Could not install \(apps[index]) in \(destinationDir), so nothing was changed and the apps already there were put back. \(message(of: error))")
            }
        }
        staged.removeAll()
        return targets
    }

    private static func message(of error: Error) -> String {
        (error as? ActionError)?.message ?? error.localizedDescription
    }

    private static func attach(_ imagePath: String) throws -> String {
        let result = try run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen", "-plist", imagePath,
        ])
        guard result.status == 0 else {
            throw ActionError("Could not open the disk image, so nothing was installed. It may be damaged, protected by a password, or ask you to accept a license agreement, which Forel cannot do for you. Open it in Finder to install it by hand. \(result.error)")
        }
        let plist = try? PropertyListSerialization.propertyList(from: result.output, options: [], format: nil)
        let entities = (plist as? [String: Any])?["system-entities"] as? [[String: Any]] ?? []
        guard let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw ActionError("The disk image did not mount, so nothing was installed.")
        }
        return mountPoint
    }

    /// Tries a normal detach first, then a forced one for a volume something
    /// still has open. Failure is ignored: the image is read-only, so a
    /// leftover mount does no harm beyond showing up in Finder.
    private static func detach(_ mountPoint: String) {
        if (try? run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"]))?.status == 0 { return }
        _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint, "-force", "-quiet"])
    }

    private struct ProcessResult {
        let status: Int32
        let output: Data
        let error: String
    }

    /// Holds what the background reader collected from stderr. Written once
    /// before `group.leave()` and read only after `group.wait()`.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Drain stderr on another thread while stdout is read here, so the
        // child can never stall on a full pipe.
        let errorHandle = stderr.fileHandleForReading
        let errorBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.data = errorHandle.readDataToEndOfFile()
            group.leave()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        // Newer macOS versions print a deprecation warning for `hdiutil`
        // even on success; it says nothing about why an install failed.
        let message = String(decoding: errorBox.data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.contains("WARNING:") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessResult(status: process.terminationStatus, output: output, error: message)
    }
}
