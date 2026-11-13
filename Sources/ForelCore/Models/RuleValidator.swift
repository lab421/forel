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

/// Validates rule-level constraints so callers can surface issues before
/// persisting a rule that would silently produce wrong results at run time.
public enum RuleValidator {
    public struct Issue: Equatable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    public static func validate(_ conditions: [Condition]) -> [Issue] {
        conditions.compactMap { condition in
            if condition.kind == .locked {
                return condition.kind.validOperators.contains(condition.operator)
                    ? nil : Issue(message: L10n.string("rule_problem_locked_requires_true_false"))
            }
            if condition.value.trimmingCharacters(in: .whitespaces).isEmpty {
                return Issue(message: L10n.string("rule_problem_condition_value_cannot_empty"))
            }
            if condition.operator == .matchesRegex,
               (try? NSRegularExpression(pattern: condition.value)) == nil {
                return Issue(message: L10n.string("rule_problem_regex_pattern_is_invalid"))
            }
            return nil
        }
    }

    public static func validate(_ actions: [Action]) -> [Issue] {
        actions.compactMap { action in
            switch action.kind {
            case .toggleLock, .toggleExtension:
                let key = action.kind == .toggleLock ? ActionParam.locked : ActionParam.extensionHidden
                if action.params[key]?.boolValue == nil {
                    return Issue(message: L10n.string("requires_true_false_value", action.kind.label))
                }
            case .moveToFolder, .copyToFolder, .syncFolders:
                if action.params[ActionParam.destination]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: L10n.string("rule_problem_destination_path_cannot_empty"))
                }
            case .rename:
                if action.params[ActionParam.pattern]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: L10n.string("rule_problem_rename_pattern_cannot_empty"))
                }
            case .compress:
                do {
                    _ = try ActionExecutor.archiveFileName(pattern: action.params[ActionParam.archiveName]?.stringValue ?? "", sourceName: "file")
                    _ = try ActionExecutor.archiveDestinationPath(action.params[ActionParam.destination]?.stringValue ?? "")
                } catch {
                    return Issue(message: String(describing: error))
                }
            case .addTag, .removeTag:
                if tags(in: action).isEmpty {
                    return Issue(message: L10n.string("rule_problem_least_one_tag_required"))
                }
            case .openApplication:
                if action.params[ActionParam.applicationPath]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: L10n.string("rule_problem_application_cannot_be_empty"))
                }
            default:
                break
            }
            return nil
        }
    }

    private static func tags(in action: Action) -> [String] {
        if let tags = action.params[ActionParam.tags]?.arrayValue {
            return tags.compactMap(\.stringValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let tag = action.params["tag"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty {
            return [tag]
        }
        return []
    }
}
