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
import Testing
@testable import ForelCore

@Suite struct RuleExpansionPreferencesTests {
    private func makeDB() throws -> Database {
        try Database(path: ":memory:")
    }

    @Test func defaultExpansionMatchesRuleCardDefaults() throws {
        let enabledRule = makeRule(folderId: UUID().uuidString, name: "enabled")
        var disabledRule = makeRule(folderId: UUID().uuidString, name: "disabled")
        disabledRule.enabled = false
        let preferences = RuleExpansionPreferences()

        #expect(preferences.isExpanded(enabledRule))
        #expect(!preferences.isExpanded(disabledRule))
    }

    @Test func toggledExpansionStatePersistsAcrossReloads() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        let enabledRule = makeRule(folderId: folder.id, name: "enabled")
        var disabledRule = makeRule(folderId: folder.id, name: "disabled")
        disabledRule.enabled = false
        try db.insertRule(enabledRule)
        try db.insertRule(disabledRule)

        var preferences = RuleExpansionPreferences.load(from: db)
        preferences.toggle(enabledRule, in: db)
        preferences.toggle(disabledRule, in: db)

        let reloaded = RuleExpansionPreferences.load(from: db)
        #expect(!reloaded.isExpanded(enabledRule))
        #expect(reloaded.isExpanded(disabledRule))
    }

    @Test func clearingDeletedRuleRemovesPersistedPreference() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        let rule = makeRule(folderId: folder.id, name: "collapsible")
        try db.insertRule(rule)

        var preferences = RuleExpansionPreferences.load(from: db)
        preferences.toggle(rule, in: db)
        #expect(!RuleExpansionPreferences.load(from: db).isExpanded(rule))

        try db.deleteRule(rule.id)
        preferences.clear(ruleId: rule.id, in: db)

        let reloaded = RuleExpansionPreferences.load(from: db)
        #expect(reloaded.collapsedRuleIds.isEmpty)
        #expect(reloaded.expandedDisabledRuleIds.isEmpty)
    }

    @Test func clearingDeletedWatchedFolderRemovesAllRulePreferences() throws {
        let db = try makeDB()
        let folder = WatchedFolder(path: "/tmp/forel-test-\(UUID().uuidString)")
        try db.insertFolder(folder)
        let enabledRule = makeRule(folderId: folder.id, name: "enabled")
        var disabledRule = makeRule(folderId: folder.id, name: "disabled")
        disabledRule.enabled = false
        try db.insertRule(enabledRule)
        try db.insertRule(disabledRule)

        var preferences = RuleExpansionPreferences.load(from: db)
        preferences.toggle(enabledRule, in: db)
        preferences.toggle(disabledRule, in: db)

        let deletedRuleIds = Set(try db.listRules(folderId: folder.id).map(\.id))
        try db.deleteFolder(folder.id)
        preferences.clear(ruleIds: deletedRuleIds, in: db)

        let reloaded = RuleExpansionPreferences.load(from: db)
        #expect(reloaded.collapsedRuleIds.isEmpty)
        #expect(reloaded.expandedDisabledRuleIds.isEmpty)
    }
}
