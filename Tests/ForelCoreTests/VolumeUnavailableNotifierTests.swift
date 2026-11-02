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

@Suite struct VolumeUnavailableNotifierTests {
    private func event(_ volumes: [String], rules: [String] = ["to nas"], willRetry: Bool = true) -> VolumeUnavailableEvent {
        VolumeUnavailableEvent(volumes: volumes, ruleNames: rules, willRetry: willRetry)
    }

    @Test func filesFailingTogetherMakeOneNotification() throws {
        var notifier = VolumeUnavailableNotifier()
        let first = notifier.add(event(["SG_Shared"]))
        let second = notifier.add(event(["SG_Shared"]))
        #expect(first)
        #expect(second)

        let made = notifier.makeNotification()
        let notification = try #require(made)
        #expect(notification.title == "“SG_Shared” isn't connected")
        #expect(notification.body == "2 files couldn't be moved or copied. Rules: to nas. Forel will try again when it's connected, if watching is still on.")
        let again = notifier.makeNotification()
        #expect(again == nil)
    }

    @Test func aMissingShareIsReportedOnceUntilItIsConnectedAgain() {
        var notifier = VolumeUnavailableNotifier()
        notifier.add(event(["SG_Shared"]))
        _ = notifier.makeNotification()

        // Still missing: later files don't notify again.
        let whileMissing = notifier.add(event(["SG_Shared"]))
        let silent = notifier.makeNotification()
        #expect(!whileMissing)
        #expect(silent == nil)

        // Connected, then missing again: reported again.
        notifier.volumeConnected("SG_Shared")
        let afterReconnect = notifier.add(event(["SG_Shared"]))
        let reported = notifier.makeNotification()
        #expect(afterReconnect)
        #expect(reported != nil)
    }

    @Test func severalSharesAndFilesThatWontBeRetried() throws {
        var notifier = VolumeUnavailableNotifier()
        notifier.add(event(["SG_Shared"], rules: ["statements"]))
        notifier.add(event(["Photos"], rules: ["photos"], willRetry: false))

        let made = notifier.makeNotification()
        let notification = try #require(made)
        #expect(notification.title == "2 disks or shares aren't connected")
        #expect(notification.body == "2 files couldn't be moved or copied. Rules: photos, statements. Connect them, then use Run Now.")
    }

    @Test func discardingKeepsWhatWasAlreadyReported() {
        var notifier = VolumeUnavailableNotifier()
        notifier.add(event(["SG_Shared"]))
        _ = notifier.makeNotification()
        notifier.add(event(["Photos"]))
        notifier.discardPending()
        let made = notifier.makeNotification()
        let reportedAgain = notifier.add(event(["SG_Shared"]))
        #expect(made == nil)
        #expect(!reportedAgain)
    }

    @Test func aShareConnectedBeforeTheNotificationIsShownIsLeftOut() throws {
        var notifier = VolumeUnavailableNotifier()
        notifier.add(event(["SG_Shared"]))
        notifier.volumeConnected("SG_Shared")
        let nothing = notifier.makeNotification()
        #expect(nothing == nil)

        notifier.add(event(["SG_Shared"]))
        notifier.add(event(["Photos"]))
        notifier.volumeConnected("SG_Shared")
        let made = notifier.makeNotification()
        let notification = try #require(made)
        #expect(notification.title == "“Photos” isn't connected")
    }
}
