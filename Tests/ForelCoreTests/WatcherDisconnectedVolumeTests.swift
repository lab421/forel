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

/// Automatic runs whose destination disk or share isn't connected: reported,
/// then run again when it comes back (`WatcherCoordinator+DisconnectedVolumes`).
@Suite struct WatcherDisconnectedVolumeTests {
    private func makeDB() throws -> Database {
        try Database(path: ":memory:")
    }

    private final class VolumeEventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [VolumeUnavailableEvent] = []

        func append(_ event: VolumeUnavailableEvent) {
            lock.lock()
            values.append(event)
            lock.unlock()
        }

        func snapshot() -> [VolumeUnavailableEvent] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// A rule moving .txt files to a share under /Volumes that isn't mounted.
    private func ruleToDisconnectedShare(folderId: String, before: [Action] = []) -> (rule: Rule, volume: String) {
        let volume = "ForelMissingShare-\(UUID().uuidString)"
        var rule = makeRule(folderId: folderId, name: "to nas")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        rule.actions = before + [
            makeAction(.moveToFolder, .object(["destination": .string("/Volumes/\(volume)/Inbox")]), position: Int64(before.count), ruleId: rule.id),
        ]
        return (rule, volume)
    }

    /// What the share's folder looks like once it is connected: the same rule,
    /// now moving into a folder that exists.
    private func reconnect(_ rule: Rule, to destination: String, in db: Database) throws {
        var connected = rule
        connected.actions = rule.actions.map { action in
            guard action.kind == .moveToFolder else { return action }
            var moved = action
            moved.params = .object(["destination": .string(destination)])
            return moved
        }
        try db.updateRule(connected)
    }

    @Test func moveToADisconnectedShareIsReportedAndRunsAgainWhenItConnects() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        let (rule, volume) = ruleToDisconnectedShare(folderId: folder.id)
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        let events = VolumeEventBox()
        coordinator.onVolumeUnavailable = { events.append($0) }

        coordinator.handle(path: file)
        #expect(events.snapshot() == [VolumeUnavailableEvent(volumes: [volume], ruleNames: ["to nas"], willRetry: true)])
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(try db.listHistory().map(\.status) == [.failed])

        // A duplicate event for the untouched file doesn't try again.
        coordinator.handle(path: file)
        #expect(try db.listHistory().count == 1)

        // Another disk connecting changes nothing.
        let inbox = dir.dir("Inbox")
        try reconnect(rule, to: inbox, in: db)
        coordinator.volumeDidMount(atPath: "/Volumes/SomeOtherDisk")
        coordinator.waitForPendingEvents()
        #expect(FileManager.default.fileExists(atPath: file))

        coordinator.volumeDidMount(atPath: "/Volumes/\(volume)")
        coordinator.waitForPendingEvents()
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: (inbox as NSString).appendingPathComponent("a.txt")))
        #expect(try db.listHistory().map(\.status).sorted { $0.rawValue < $1.rawValue } == [.applied, .failed].sorted { $0.rawValue < $1.rawValue })

        // Once done, connecting again doesn't run anything more.
        coordinator.volumeDidMount(atPath: "/Volumes/\(volume)")
        coordinator.waitForPendingEvents()
        #expect(try db.listHistory().count == 2)
    }

    @Test func fileStillWaitsWhenTheShareIsStillUnreachableAfterMounting() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        let (rule, volume) = ruleToDisconnectedShare(folderId: folder.id)
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        let events = VolumeEventBox()
        coordinator.onVolumeUnavailable = { events.append($0) }
        coordinator.handle(path: file)

        // Retried, failed again: it keeps waiting for the next connection.
        coordinator.volumeDidMount(atPath: "/Volumes/\(volume)")
        coordinator.waitForPendingEvents()
        #expect(try db.listHistory().map(\.status) == [.failed, .failed])
        #expect(events.snapshot().count == 2)

        let inbox = dir.dir("Inbox")
        try reconnect(rule, to: inbox, in: db)
        coordinator.volumeDidMount(atPath: "/Volumes/\(volume)")
        coordinator.waitForPendingEvents()
        #expect(FileManager.default.fileExists(atPath: (inbox as NSString).appendingPathComponent("a.txt")))
    }

    @Test func fileIsNotRunAgainWhenAnotherActionWasAlreadyApplied() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        let backup = dir.dir("Backup")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        let copy = makeAction(.copyToFolder, .object(["destination": .string(backup)]), position: 0, ruleId: "placeholder")
        var (rule, volume) = ruleToDisconnectedShare(folderId: folder.id, before: [copy])
        rule.actions[0].ruleId = rule.id
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        let events = VolumeEventBox()
        coordinator.onVolumeUnavailable = { events.append($0) }
        coordinator.handle(path: file)

        #expect(events.snapshot() == [VolumeUnavailableEvent(volumes: [volume], ruleNames: ["to nas"], willRetry: false)])
        try reconnect(rule, to: dir.dir("Inbox"), in: db)
        coordinator.volumeDidMount(atPath: "/Volumes/\(volume)")
        coordinator.waitForPendingEvents()

        // The copy isn't made a second time.
        let copies = try FileManager.default.contentsOfDirectory(atPath: backup)
        #expect(copies == ["a.txt"])
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func fileIsNotRunAgainOnceItsFolderIsNoLongerWatched() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        let (rule, volume) = ruleToDisconnectedShare(folderId: folder.id)
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        coordinator.handle(path: file)

        // Watching paused, folder disabled or removed.
        coordinator.remove(dir.path)
        try reconnect(rule, to: dir.dir("Inbox"), in: db)
        coordinator.volumeDidMount(atPath: "/Volumes/\(volume)")
        coordinator.waitForPendingEvents()

        #expect(FileManager.default.fileExists(atPath: file))
        #expect(try db.listHistory().count == 1)
    }

    @Test func otherFailuresAreNotReportedAsADisconnectedShare() throws {
        let db = try makeDB()
        let dir = TempDir()
        let file = dir.file("a.txt")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "to system")
        rule.conditions = [makeCondition(.extension_, .is, "txt", ruleId: rule.id)]
        // Fails because it can't be written to, on a disk that is connected.
        rule.actions = [makeAction(.moveToFolder, .object(["destination": .string("/System/ForelNotWritable")]), position: 0, ruleId: rule.id)]
        try db.insertRule(rule)

        let coordinator = WatcherCoordinator(db: db)
        let events = VolumeEventBox()
        coordinator.onVolumeUnavailable = { events.append($0) }
        coordinator.handle(path: file)

        #expect(try db.listHistory().map(\.status) == [.failed])
        #expect(events.snapshot().isEmpty)
    }
}
