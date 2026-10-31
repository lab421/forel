import Foundation
import AVFoundation

/// Loads a video's embedded creation date with a bounded wait. No filesystem
/// timestamp is substituted when metadata is unavailable.
enum VideoDateTaken {
    private static let inFlight = DispatchSemaphore(value: 4)
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date?
        func set(_ date: Date?) { lock.lock(); value = date; lock.unlock() }
        func get() -> Date? { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func read(path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        guard ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, size <= 1_000_000_000 else { return nil }
        guard inFlight.wait(timeout: .now()) == .success else { return nil }
        let box = ResultBox(), done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            defer { done.signal(); inFlight.signal() }
            let asset = AVURLAsset(url: url)
            guard let items = try? await asset.load(.commonMetadata) else { return }
            for item in items where item.commonKey == .commonKeyCreationDate {
                if let date = try? await item.load(.dateValue) { box.set(date); return }
                if let text = try? await item.load(.stringValue) {
                    let iso = ISO8601DateFormatter()
                    if let date = iso.date(from: text) { box.set(date); return }
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = iso.date(from: text) { box.set(date); return }
                }
            }
        }
        guard done.wait(timeout: .now() + 3) == .success else { task.cancel(); return nil }
        return box.get()
    }
}
