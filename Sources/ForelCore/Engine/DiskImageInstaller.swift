import Foundation

/// Mounts a disk image read-only, copies the applications at its top level
/// into a folder, and unmounts it again. Used by the "Install disk image"
/// action.
enum DiskImageInstaller {
    /// Formats `hdiutil` can attach. Bundle-style `.sparsebundle` images are
    /// directories and are left out.
    static let supportedExtensions: Set<String> = ["dmg", "iso", "img", "sparseimage"]

    static func isSupported(_ path: String) -> Bool {
        supportedExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Copies every top-level `.app` into `destinationDir` and returns the
    /// installed paths. Without `replaceExisting`, nothing is copied if any
    /// app already exists there. With it, each new copy is made beside the
    /// old app first, and only then does it take the old app's place. The
    /// old app goes to the Trash, so it can still be restored. If copying
    /// fails, the installed apps are left as they were.
    /// The image is always unmounted before this returns.
    static func install(
        imagePath: String,
        into destinationDir: String,
        replaceExisting: Bool = false,
        moveToTrash: (String) throws -> Void = { try FileManager.default.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil) }
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
        // Copies that have not been moved into place yet. Whatever is left
        // when this function exits is removed, so a failure leaves no partial copy.
        var staged: [String] = []
        defer { for copy in staged { try? fm.removeItem(atPath: copy) } }
        for app in apps {
            let source = (mountPoint as NSString).appendingPathComponent(app)
            let copy = (destinationDir as NSString).appendingPathComponent(".forel-install-\(UUID().uuidString)-\(app)")
            // `ditto` keeps code signatures and resource forks, which a plain copy can drop.
            let result = try run("/usr/bin/ditto", [source, copy])
            guard result.status == 0 else {
                throw ActionError("Could not copy \(app) to \(destinationDir). \(result.error)")
            }
            staged.append(copy)
        }
        for (copy, target) in zip(staged, targets) {
            if fm.fileExists(atPath: target) {
                try moveToTrash(target)
            }
            try fm.moveItem(atPath: copy, toPath: target)
        }
        staged.removeAll()
        return targets
    }

    private static func attach(_ imagePath: String) throws -> String {
        let result = try run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen", "-plist", imagePath,
        ])
        guard result.status == 0 else {
            throw ActionError("Could not open the disk image. Encrypted or damaged images are not supported. \(result.error)")
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

    private static func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Read both pipes to the end before waiting, so a full pipe cannot stall the child.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessResult(status: process.terminationStatus, output: output, error: message)
    }
}
