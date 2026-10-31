import Foundation
import Darwin

enum HazelScriptConditionRunner {
    struct Result {
        let matched: Bool
        let attributes: [String: JSONValue]
    }

    static func run(spec: HazelScriptCondition, path: String, attributes: [String: JSONValue]) throws -> Result {
        if let error = spec.validationError { throw ActionError(error) }
        if spec.language == .shell { return Result(matched: try shell(spec, path: path), attributes: [:]) }
        let url = URL(fileURLWithPath: path)
        let inputs: [JSONValue] = try spec.inputNames.map { name in
            switch name {
            case "path": return .string(url.path)
            case "name": return .string(url.deletingPathExtension().lastPathComponent)
            case "fullName": return .string(url.lastPathComponent)
            case "extension": return .string(url.pathExtension)
            case "comment": return .string(try FinderComment.read(path) ?? "")
            case "dateAdded", "dateCreated", "dateModified", "currentDate", "hazelbuiltin:dateTaken":
                return .object(["__forelDate": .number(try HazelPattern.dateValue(name, path: path).timeIntervalSince1970)])
            default:
                guard let value = attributes[name] else { throw ActionError("Script input attribute \(name) is unavailable") }
                return value
            }
        }
        let language: HazelOSARunner.Language = spec.language == .appleScript ? .appleScript : .javaScript
        let source: HazelOSARunner.Source
        if let external = spec.externalPath { source = .external(external) }
        else if let data = spec.compiledData.flatMap({ Data(base64Encoded: $0) }) { source = .compiled(data) }
        else { source = spec.sourceIsHandler == true ? .sourceHandler(spec.source) : .embedded(spec.source) }
        let result = try HazelOSARunner.run(language: language, source: source, path: path, inputs: inputs, purpose: .condition)
        guard let matched = result.passes else { throw ActionError("Condition script did not return a match result") }
        guard result.orderedAttributes.count == spec.outputNames.count else { throw ActionError("Condition script output attributes do not match their configuration") }
        return Result(matched: matched, attributes: matched ? Dictionary(uniqueKeysWithValues: zip(spec.outputNames, result.orderedAttributes)) : [:])
    }

    private static func shell(_ spec: HazelScriptCondition, path: String) throws -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forel-condition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        if let external = spec.externalPath {
            process.executableURL = URL(fileURLWithPath: external)
            process.arguments = [URL(fileURLWithPath: path).standardizedFileURL.path]
        } else {
            guard !spec.source.contains("\0"), spec.source.utf8.count <= 1_000_000 else { throw ActionError("Invalid shell condition source") }
            let script = directory.appendingPathComponent("script")
            try Data(spec.source.utf8).write(to: script, options: .atomic)
            process.executableURL = URL(fileURLWithPath: spec.interpreter)
            process.arguments = [script.path, URL(fileURLWithPath: path).standardizedFileURL.path]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ActionError("Cannot start condition script: \(error.localizedDescription)") }
        let started = Date()
        while process.isRunning && Date().timeIntervalSince(started) < 30 { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate(); Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit(); throw ActionError("Condition script timed out")
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit else { throw ActionError("Condition script terminated by signal") }
        return process.terminationStatus == 0
    }
}
