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

/// What one rule would do in its folder right now, for the rule editor's
/// live preview. Built with the same matching and planning as Dry Run.
public struct RuleMatchSummary: Equatable, Sendable {
    public struct Match: Identifiable, Equatable, Sendable {
        public let path: String
        public let name: String
        /// The first action's plan, e.g. "Move to ~/Archive/2026".
        public let action: String?
        /// Why that action would fail, when already known.
        public let warning: String?
        /// `false` when the action would be skipped or blocked (e.g. by a
        /// name conflict); `action` then says why.
        public let wouldRun: Bool
        public var id: String { path }
    }

    /// Items of the folder whose conditions were evaluated.
    public var checked = 0
    /// Items among them the rule matches.
    public var total = 0
    /// The first matches, in folder order.
    public var matches: [Match] = []
    /// `false` when the scan stopped before the end of the folder.
    public var isComplete = true

    public init() {}
}

extension RuleEngine {
    /// Evaluates `rule` on the items of `root` within its scope, as if it
    /// were enabled, without changing anything. Stops after `scanLimit`
    /// items, or as soon as `isCancelled` returns `true`, so large folders
    /// stay responsive while the rule is being edited.
    public static func previewMatches(
        of rule: Rule,
        root: String,
        isPro: Bool,
        scanLimit: Int = 5_000,
        keep: Int = 50,
        isCancelled: () -> Bool = { false }
    ) -> RuleMatchSummary {
        var draft = rule
        draft.enabled = true
        var summary = RuleMatchSummary()
        forEachEntry(root: root, maxDepth: maxRuleDepth([draft]), while: { entry in
            if summary.checked >= scanLimit || isCancelled() {
                summary.isComplete = false
                return false
            }
            summary.checked += 1
            guard let preview = previewFile(path: entry.path, depth: entry.depth, rules: [draft], root: root, isPro: isPro),
                  let rulePreview = preview.rules.first(where: { $0.ruleId == draft.id }) else {
                return true
            }
            summary.total += 1
            if summary.matches.count < keep {
                let first = rulePreview.actions.first
                summary.matches.append(RuleMatchSummary.Match(
                    path: preview.path,
                    name: preview.name,
                    action: first?.description,
                    warning: first?.warning,
                    wouldRun: first?.status == .wouldRun
                ))
            }
            return true
        })
        return summary
    }
}
