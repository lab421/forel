import Foundation
import Darwin

/// A debug-only, explicitly configured sink for hermetic filesystem tests.
enum TestingTrash {
    static func configuredDirectory() throws -> String? {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["FOREL_TEST_TRASH_DIRECTORY"] else { return nil }
        return try validate(path)
        #else
        return nil
        #endif
    }

    #if DEBUG
    static func validate(_ path: String) throws -> String {
        guard !path.isEmpty, (path as NSString).isAbsolutePath else { throw ActionError("Invalid test Trash directory") }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ActionError("Test Trash directory must be an existing real directory")
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { throw ActionError("Cannot resolve test Trash directory") }
        let resolved = String(cString: buffer)
        let components = (resolved as NSString).pathComponents
        guard components.count >= 4, components[1] == "private", components[2] == "tmp", components[3].hasPrefix("forel-hazel-") else {
            throw ActionError("Test Trash directory must be inside /tmp/forel-hazel-*")
        }
        return resolved
    }
    #endif

    static func move(_ path: String, into directory: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 0..<10_000 {
            let candidateName = index == 0 ? name : (ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)")
            let candidate = (directory as NSString).appendingPathComponent(candidateName)
            do { try FileManager.default.moveItem(atPath: path, toPath: candidate); return candidate }
            catch {
                var info = stat()
                if lstat(candidate, &info) == 0 { continue }
                throw error
            }
        }
        throw ActionError("Test Trash is full")
    }
}
