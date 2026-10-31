// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import Foundation
import Darwin

enum AutomatorRunner {
    static func run(workflowPath: String, inputPath: String) throws {
        guard FileManager.default.fileExists(atPath: workflowPath) else { throw ActionError("The Automator workflow does not exist") }
        let source = #"""
        use framework "Foundation"
        use framework "Automator"
        use scripting additions
        on run argv
          set workflowURL to current application's NSURL's fileURLWithPath:(item 1 of argv)
          set inputURL to current application's NSURL's fileURLWithPath:(item 2 of argv)
          set {workflowResult, workflowError} to current application's AMWorkflow's runWorkflowAtURL:workflowURL withInput:{inputURL} |error|:(reference)
          if workflowError is not missing value then error (workflowError's localizedDescription() as text)
        end run
        """#
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forel-automator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let errorsURL = directory.appendingPathComponent("errors")
        guard FileManager.default.createFile(atPath: errorsURL.path, contents: nil) else { throw ActionError("Cannot prepare Automator error output") }
        let errors = try FileHandle(forWritingTo: errorsURL)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "AppleScript", "-e", source, "--", workflowPath, URL(fileURLWithPath: inputPath).standardizedFileURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do { try process.run() } catch { throw ActionError("Cannot start Automator: \(error.localizedDescription)") }
        let start = Date()
        while process.isRunning && Date().timeIntervalSince(start) < 60 { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ActionError("Automator workflow timed out after 60s")
        }
        process.waitUntilExit()
        try errors.close()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: errorsURL)
            defer { try? reader.close() }
            let message = String(decoding: try reader.read(upToCount: 4096) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ActionError("Automator workflow failed\(message.isEmpty ? "" : ": \(message)")")
        }
    }
}
