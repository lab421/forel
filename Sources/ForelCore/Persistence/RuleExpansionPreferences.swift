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

public struct RuleExpansionPreferences: Equatable, Sendable {
    public static let collapsedRuleIdsSettingKey = "collapsed_rule_ids"
    public static let expandedDisabledRuleIdsSettingKey = "expanded_disabled_rule_ids"

    public private(set) var collapsedRuleIds: Set<String>
    public private(set) var expandedDisabledRuleIds: Set<String>

    public init(collapsedRuleIds: Set<String> = [], expandedDisabledRuleIds: Set<String> = []) {
        self.collapsedRuleIds = collapsedRuleIds
        self.expandedDisabledRuleIds = expandedDisabledRuleIds
    }

    public static func load(from db: Database) -> RuleExpansionPreferences {
        RuleExpansionPreferences(
            collapsedRuleIds: loadRuleIdSet(from: db, key: collapsedRuleIdsSettingKey),
            expandedDisabledRuleIds: loadRuleIdSet(from: db, key: expandedDisabledRuleIdsSettingKey)
        )
    }

    public func isExpanded(_ rule: Rule) -> Bool {
        rule.enabled ? !collapsedRuleIds.contains(rule.id) : expandedDisabledRuleIds.contains(rule.id)
    }

    public mutating func toggle(_ rule: Rule, in db: Database) {
        if rule.enabled {
            if collapsedRuleIds.contains(rule.id) {
                collapsedRuleIds.remove(rule.id)
            } else {
                collapsedRuleIds.insert(rule.id)
            }
            persist(collapsedRuleIds, key: Self.collapsedRuleIdsSettingKey, in: db)
        } else {
            if expandedDisabledRuleIds.contains(rule.id) {
                expandedDisabledRuleIds.remove(rule.id)
            } else {
                expandedDisabledRuleIds.insert(rule.id)
            }
            persist(expandedDisabledRuleIds, key: Self.expandedDisabledRuleIdsSettingKey, in: db)
        }
    }

    public mutating func clear(ruleId: String, in db: Database) {
        clear(ruleIds: Set([ruleId]), in: db)
    }

    public mutating func clear(ruleIds: Set<String>, in db: Database) {
        guard !ruleIds.isEmpty else { return }
        let oldCollapsed = collapsedRuleIds
        let oldExpandedDisabled = expandedDisabledRuleIds
        collapsedRuleIds.subtract(ruleIds)
        expandedDisabledRuleIds.subtract(ruleIds)
        if collapsedRuleIds != oldCollapsed {
            persist(collapsedRuleIds, key: Self.collapsedRuleIdsSettingKey, in: db)
        }
        if expandedDisabledRuleIds != oldExpandedDisabled {
            persist(expandedDisabledRuleIds, key: Self.expandedDisabledRuleIdsSettingKey, in: db)
        }
    }

    private static func loadRuleIdSet(from db: Database, key: String) -> Set<String> {
        guard
            let rawValue = try? db.getSetting(key),
            let data = rawValue.data(using: .utf8),
            let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(values)
    }

    private func persist(_ values: Set<String>, key: String, in db: Database) {
        let data = try? JSONEncoder().encode(values.sorted())
        let rawValue = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try? db.setSetting(key, rawValue)
    }
}
