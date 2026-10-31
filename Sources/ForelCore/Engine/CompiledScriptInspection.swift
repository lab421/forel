// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import Foundation
import Darwin

/// Decompilation inspects script bytes; it does not execute the script.
public enum CompiledScriptInspection {
    public static func source(from data: Data) throws -> String {
        guard data.count <= 1_000_000, data.starts(with: Data("Fasd".utf8)) || data.starts(with: Data("JsOsa".utf8)) else {
            throw ActionError("Invalid compiled script")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forel-decompile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("script.scpt")
        let output = directory.appendingPathComponent("source")
        try data.write(to: input, options: .atomic)
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw ActionError("Cannot prepare script inspection") }
        let outputHandle = try FileHandle(forWritingTo: output)
        defer { try? outputHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osadecompile")
        process.arguments = [input.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate(); Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ActionError("Script inspection timed out")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ActionError("Could not decompile the script") }
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let bytes = try reader.read(upToCount: 1_000_001) ?? Data()
        guard bytes.count <= 1_000_000, let source = String(data: bytes, encoding: .utf8), !source.contains("\0") else {
            throw ActionError("Decompiled script is too large or invalid")
        }
        return source
    }
}
