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
        let title = one
            ? String(localized: "“\(volumes[0])” isn't connected", bundle: .forelStrings, comment: "Notification when a destination disk or share isn’t connected")
            : String(localized: "\(volumes.count) disks or shares aren't connected", bundle: .forelStrings, comment: "Notification when a destination disk or share isn’t connected")

        let ruleNames = pendingRuleNames.sorted()
        let visibleRules = ruleNames.prefix(3).joined(separator: ", ")
        let remainingRuleCount = ruleNames.count - ruleNames.prefix(3).count
        let rulesText = remainingRuleCount > 0
            ? String(localized: "\(visibleRules) and \(remainingRuleCount) more", bundle: .forelStrings, comment: "Rule names in a notification; %1$@ lists up to three of them")
            : visibleRules
        let problem = String(localized: "\(pendingFileCount) files couldn't be moved or copied. Rules: \(rulesText).", bundle: .forelStrings, comment: "Notification when a destination disk or share isn’t connected")
        let next = switch (pendingAllRetry, one) {
        case (true, true): String(localized: "Forel will try again when it's connected, if watching is still on.", bundle: .forelStrings, comment: "Notification when a destination disk or share isn’t connected")
        case (true, false): String(localized: "Forel will try again when they're connected, if watching is still on.", bundle: .forelStrings, comment: "Notification when a destination disk or share isn’t connected")
        case (false, true): String(localized: "Connect it, then use Run Now.", bundle: .forelStrings, comment: "Notification when a destination disk or share isn’t connected")
        case (false, false): String(localized: "Connect them, then use Run Now.", bundle: .forelStrings, comment: "Notification when a destination disk or share isn’t connected")
        }
        let body = "\(problem) \(next)"

        reported.formUnion(pendingVolumes)
        discardPending()
        return (title, body)
    }
}
