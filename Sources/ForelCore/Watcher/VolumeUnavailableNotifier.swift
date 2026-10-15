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

import Foundation

/// Decides what to tell the user when automatic rules can't reach a disk or
/// network share: one notification per disk or share each time it goes
/// missing, not one per file, until it is connected again.
public struct VolumeUnavailableNotifier: Sendable {
    /// Disks or shares a notification was already shown for.
    private var reported: Set<String> = []
    /// What the next notification will be about.
    private var pendingVolumes: Set<String> = []
    private var pendingFileCount = 0
    private var pendingRuleNames: Set<String> = []
    private var pendingAllRetry = true

    public init() {}

    /// Collects `event` for the next notification. Returns false when its
    /// disks or shares were all already reported since they went missing.
    @discardableResult
    public mutating func add(_ event: VolumeUnavailableEvent) -> Bool {
        let unreported = Set(event.volumes).subtracting(reported)
        guard !unreported.isEmpty else { return false }
        pendingVolumes.formUnion(unreported)
        pendingFileCount += 1
        pendingRuleNames.formUnion(event.ruleNames)
        pendingAllRetry = pendingAllRetry && event.willRetry
        return true
    }

    /// The disk or share is back: the next time it goes missing is reported,
    /// and a notification not shown yet no longer claims it's missing.
    public mutating func volumeConnected(_ volume: String) {
        reported.remove(volume)
        pendingVolumes.remove(volume)
        if pendingVolumes.isEmpty { discardPending() }
    }

    /// Drops what was collected, e.g. when notifications are turned off.
    public mutating func discardPending() {
        self = VolumeUnavailableNotifier(reported: reported)
    }

    private init(reported: Set<String>) {
        self.reported = reported
    }

    /// The notification for what was collected since the last one, if any.
    public mutating func makeNotification() -> (title: String, body: String)? {
        guard !pendingVolumes.isEmpty else { return nil }
        let volumes = pendingVolumes.sorted()
        let one = volumes.count == 1
        let title = one ? "“\(volumes[0])” isn't connected" : "\(volumes.count) disks or shares aren't connected"

        let fileLabel = pendingFileCount == 1 ? "file" : "files"
        let ruleNames = pendingRuleNames.sorted()
        let visibleRules = ruleNames.prefix(3)
        let remainingRuleCount = ruleNames.count - visibleRules.count
        let rulesText = visibleRules.joined(separator: ", ")
            + (remainingRuleCount > 0 ? " and \(remainingRuleCount) more" : "")
        let next = pendingAllRetry
            ? "Forel will try again when \(one ? "it's" : "they're") connected, if watching is still on."
            : "Connect \(one ? "it" : "them"), then use Run Now."
        let body = "\(pendingFileCount) \(fileLabel) couldn't be moved or copied. Rules: \(rulesText). \(next)"

        reported.formUnion(pendingVolumes)
        discardPending()
        return (title, body)
    }
}
