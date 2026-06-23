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

import CoreServices
import Foundation

public enum FileWatcherEvent: Equatable, Sendable {
    case pathArrived(String)
    case rescanSubtree(String)
}

/// Native FSEvents-based replacement for the Rust `notify` watcher. Watches a
/// dynamic set of folder paths recursively. It normally reports newly arrived
/// paths (created in, renamed inside, or moved into a watched folder). If
/// FSEvents says detailed events were dropped, it reports a subtree rescan
/// request instead. The underlying `FSEventStream` cannot have its
/// path set mutated in place, so adding/removing a folder recreates the stream
/// with the updated set — same externally-visible behaviour as the old
/// `WatcherCmd::Add`/`Remove` channel.
public final class FileWatcher: @unchecked Sendable {
    public typealias EventHandler = @Sendable (_ event: FileWatcherEvent) -> Void

    private var onEvent: EventHandler
    private let lock = NSLock()
    private var watchedPaths: Set<String> = []
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.forel.filewatcher")
    private let latency: CFTimeInterval = 0.3

    public init(onEvent: @escaping EventHandler) {
        self.onEvent = onEvent
    }

    public func replaceHandler(_ handler: @escaping EventHandler) {
        lock.lock()
        onEvent = handler
        lock.unlock()
    }

    deinit {
        stopStream()
    }

    public func add(_ path: String) {
        lock.lock()
        let inserted = watchedPaths.insert(path).inserted
        let paths = watchedPaths
        lock.unlock()
        if inserted { rebuildStream(paths: paths) }
    }

    public func remove(_ path: String) {
        lock.lock()
        watchedPaths.remove(path)
        let paths = watchedPaths
        lock.unlock()
        rebuildStream(paths: paths)
    }

    private func rebuildStream(paths: Set<String>) {
        stopStream()
        guard !paths.isEmpty else { return }

        let context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        var ctx = context
        let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &ctx,
            Array(paths) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        )

        guard let newStream else { return }
        FSEventStreamSetDispatchQueue(newStream, queue)
        FSEventStreamStart(newStream)
        lock.lock()
        stream = newStream
        lock.unlock()
    }

    private func stopStream() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    /// Forel's automatic watcher is arrival-oriented in normal operation: it
    /// starts rules when a path appears in the watched tree, not every time an
    /// existing file is edited. Duplicate/coalesced create/rename events are
    /// handled downstream by `WatcherCoordinator`'s fingerprint cache.
    ///
    /// Do not add `ItemModified`/`ItemXattrMod` here casually. Those would make
    /// Forel re-evaluate existing files whenever content, tags, labels, or
    /// download metadata change, which is a broader product behavior than
    /// "run rules for newly arrived files".
    ///
    /// `MustScanSubDirs`/dropped events are different: they mean FSEvents lost
    /// detail and the safe recovery is to rescan the affected subtree. The
    /// coordinator still skips unchanged paths using its fingerprint cache.
    static func reportedEvent(path: String, flags: FSEventStreamEventFlags) -> FileWatcherEvent? {
        if SystemFileFilter.isExcluded((path as NSString).lastPathComponent) { return nil }

        let needsRescan = flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
            || flags & UInt32(kFSEventStreamEventFlagUserDropped) != 0
            || flags & UInt32(kFSEventStreamEventFlagKernelDropped) != 0
        if needsRescan {
            return .rescanSubtree(path)
        }

        return shouldReportEvent(path: path, flags: flags) ? .pathArrived(path) : nil
    }

    static func shouldReportEvent(path: String, flags: FSEventStreamEventFlags) -> Bool {
        let isArrival = flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
            || flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        guard isArrival else { return false }
        return !SystemFileFilter.isExcluded((path as NSString).lastPathComponent)
    }

    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        lock.lock()
        let handler = onEvent
        lock.unlock()

        for (index, path) in paths.enumerated() {
            guard let event = Self.reportedEvent(path: path, flags: flags[index]) else { continue }
            handler(event)
        }
    }
}

private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    let watcher = Unmanaged<FileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    guard let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
    let flags = (0..<numEvents).map { eventFlags[$0] }
    watcher.handleEvents(paths: cfPaths, flags: flags)
}
