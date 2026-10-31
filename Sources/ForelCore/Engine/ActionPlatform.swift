import Foundation
import AppKit
import UserNotifications
import Darwin

/// The external effects of an action. Supplying an implementation allows
/// callers to test rules without opening apps or displaying notifications.
public protocol ActionPlatform: Sendable {
    func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws
    func showInFinder(path: String, bringToFront: Bool) throws
    func notify(text: String, sound: Bool) throws
    func pause(seconds: TimeInterval) throws
    func trash(path: String) throws -> String
    func runWorkflow(workflowPath: String, inputPath: String) throws
    func upload(path: String, configuration: UploadConfiguration) throws
}

public extension ActionPlatform {
    func runWorkflow(workflowPath: String, inputPath: String) throws {
        try AutomatorRunner.run(workflowPath: workflowPath, inputPath: inputPath)
    }
    func upload(path: String, configuration: UploadConfiguration) throws {
        let password = try UploadCredentials.load(for: configuration.credentialID, configuration: configuration)
        try SystemUploadTransport().upload(path: path, configuration: configuration, password: password)
    }
}

public struct MacActionPlatform: ActionPlatform {
    private final class NotificationResult: @unchecked Sendable {
        private let lock = NSLock()
        private var message: String?
        func set(_ value: String?) { lock.lock(); defer { lock.unlock() }; message = value }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return message }
    }
    private final class NotificationRequestBox: @unchecked Sendable {
        let center: UNUserNotificationCenter
        let request: UNNotificationRequest
        init(center: UNUserNotificationCenter, request: UNNotificationRequest) { self.center = center; self.request = request }
    }
    public init() {}

    public func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws {
        if let application, !application.isEmpty {
            guard FileManager.default.fileExists(atPath: application) else { throw ActionError("Application not found at \(application)") }
        }
        guard application?.isEmpty == false || passFile else { throw ActionError("Choose an application or an item to open") }
        var args: [String] = bringToFront ? [] : ["-g"]
        if let application, !application.isEmpty { args += ["-a", application] }
        if passFile { args.append(path) }
        try runProcess("/usr/bin/open", arguments: args, operation: "Open")
    }

    public func showInFinder(path: String, bringToFront: Bool) throws {
        try runProcess("/usr/bin/osascript", arguments: ["-e", "on run argv\n tell application \"Finder\"\n reveal POSIX file (item 1 of argv)\n if item 2 of argv is \"yes\" then activate\n end tell\nend run", path, bringToFront ? "yes" : "no"], operation: "Show in Finder")
    }

    private func runProcess(_ executable: String, arguments: [String], operation: String) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("forel-action-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ActionError("Could not prepare \(operation)") }
        defer { try? FileManager.default.removeItem(at: temp) }
        let errorFile = try FileHandle(forWritingTo: temp)
        defer { try? errorFile.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errorFile
        do { try task.run() } catch { throw ActionError("\(operation) could not start: \(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(20)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if task.isRunning {
            task.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
            throw ActionError("\(operation) timed out")
        }
        task.waitUntilExit()
        if task.terminationReason != .exit || task.terminationStatus != 0 {
            try errorFile.close()
            let reader = try FileHandle(forReadingFrom: temp)
            defer { try? reader.close() }
            let detail = String(decoding: try reader.read(upToCount: 4096) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ActionError("\(operation) failed\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }

    public func notify(text: String, sound: Bool) throws {
        guard Bundle.main.bundleIdentifier != nil else { throw ActionError("Notifications require the Forel application") }
        let content = UNMutableNotificationContent()
        content.title = "Forel"
        content.body = text
        if sound { content.sound = .default }
        let center = UNUserNotificationCenter.current()
        let request = NotificationRequestBox(center: center, request: UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        let result = NotificationResult()
        let finished = DispatchSemaphore(value: 0)
        center.getNotificationSettings { settings in
            let send: @Sendable () -> Void = {
                request.center.add(request.request) { error in
                    result.set(error?.localizedDescription)
                    finished.signal()
                }
            }
            if settings.authorizationStatus == .notDetermined {
                request.center.requestAuthorization(options: [.alert, .sound]) { allowed, error in
                    if allowed { send() }
                    else { result.set(error?.localizedDescription ?? "Notifications are not allowed"); finished.signal() }
                }
            } else if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                send()
            } else {
                result.set("Notifications are not allowed")
                finished.signal()
            }
        }
        guard finished.wait(timeout: .now() + 30) == .success else { throw ActionError("Timed out while sending notification") }
        if let message = result.get() { throw ActionError(message) }
    }

    public func pause(seconds: TimeInterval) throws { Thread.sleep(forTimeInterval: seconds) }

    public func trash(path: String) throws -> String {
        if let directory = try TestingTrash.configuredDirectory() { return try TestingTrash.move(path, into: directory) }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
        guard let resultingPath = resultingURL?.path else { throw ActionError("Could not locate the item in Trash") }
        return resultingPath
    }
}
