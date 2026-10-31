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
    public static func validateExecutionMode(_ rule: Rule) -> [Issue] {
        if !rule.isHazelImported && rule.actions.contains(where: { $0.kind == .hazelRecurse || $0.kind == .hazelContinue }) {
            return [Issue(message: "Enable Hazel rule ordering to use Run Rules on Folder Contents or Continue Matching Rules.")]
        }
        return []
    }
    public struct Issue: Equatable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    public static func validate(_ conditions: [Condition]) -> [Issue] {
        validateConditions(conditions, level: 0)
    }

    private static func validateConditions(_ conditions: [Condition], level: Int) -> [Issue] {
        guard level < 16, conditions.count <= 1000 else { return [Issue(message: "Nested conditions are too deep or numerous")] }
        if conditions.filter({ $0.kind == .peerRanking }).count > 1 { return [Issue(message: "Multiple peer rankings in one group are not yet supported")] }
        return conditions.compactMap { condition in
            if ChangeCondition.isChange(condition) {
                return condition.kind.validOperators.contains(condition.operator) ? nil : Issue(message: "This attribute does not support change tracking")
            }
            if condition.kind == .anyFile {
                return condition.operator == .is ? nil : Issue(message: "Any file condition has an invalid operator")
            }
            if condition.kind == .conditionGroup {
                guard condition.operator == .is, let group = ConditionGroup.decode(condition.value), !group.conditions.isEmpty else {
                    return Issue(message: "Nested conditions must contain at least one valid condition")
                }
                return validateConditions(group.conditions, level: level + 1).first
            }
            if condition.kind == .spotlightAttribute || condition.kind == .scriptAttribute {
                guard let spec = SpotlightCondition.decode(condition.value) else { return Issue(message: "Invalid Spotlight attribute condition") }
                return spec.validationError(for: condition.operator, scriptAttribute: condition.kind == .scriptAttribute).map { Issue(message: $0) }
            }
            if condition.kind == .hazelScriptCondition {
                guard condition.operator == .is, let spec = HazelScriptCondition.decode(condition.value) else { return Issue(message: "Invalid condition script") }
                return spec.validationError.map { Issue(message: $0) }
            }
            if condition.kind == .customTableMatch {
                guard condition.operator == .is, let spec = CustomTableCondition.decode(condition.value) else { return Issue(message: "Invalid custom table match") }
                return spec.validationError.map { Issue(message: $0) }
            }
            if condition.kind == .customDateMatch {
                guard condition.operator == .is, let spec = CustomDateCondition.decode(condition.value) else { return Issue(message: "Invalid custom date match") }
                return spec.validationError.map { Issue(message: $0) }
            }
            if condition.kind == .customTextMatch {
                guard condition.operator == .is, let spec = CustomTextCondition.decode(condition.value) else { return Issue(message: "Invalid custom text match") }
                return spec.validationError.map { Issue(message: $0) }
            }
            if condition.kind == .dateComparison {
                guard condition.operator == .is, let spec = DateComparisonCondition.decode(condition.value), spec.isValid else { return Issue(message: "Enter a valid date comparison") }
                return nil
            }
            if condition.kind == .peerRanking {
                guard let spec = PeerRankingCondition.decode(condition.value), [.is, .isNot].contains(condition.operator) else { return Issue(message: "Invalid peer ranking") }
                return spec.validationError.map { Issue(message: $0) }
            }
            if condition.kind == .contentsWithPassword {
                guard let spec = PasswordContentCondition.decode(condition.value), spec.referenceIsValid else { return Issue(message: "Save a PDF password in Keychain") }
                if ![Operator.isBlank, .isNotBlank].contains(condition.operator), spec.operand.isEmpty { return Issue(message: "Enter content to match") }
                if condition.operator == .matchesRegex, (try? NSRegularExpression(pattern: spec.operand)) == nil { return Issue(message: "Enter a valid regular expression") }
                return nil
            }
            if condition.kind == .currentTime,
               (condition.operator != .is || !CurrentTimeCondition.isValid(condition.value)) {
                return Issue(message: "Enter a valid time and calendar restrictions")
            }
            if condition.kind == .locked, !["true", "false"].contains(condition.value) {
                return Issue(message: "Choose whether the item is locked")
            }
            if [.beforeToday, .beforeThisWeek, .beforeThisMonth, .notThisWeek, .notThisMonth, .afterLastModified, .beforeLastModified, .isBlank, .isNotBlank].contains(condition.operator) { return nil }
            if condition.value.trimmingCharacters(in: .whitespaces).isEmpty {
                return Issue(message: "Condition value cannot be empty")
            }
            if [.subfolderDepth, .subfileCount].contains(condition.kind),
               (Int(condition.value.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 >= 0 } != true) {
                return Issue(message: "Subfolder depth must be a non-negative whole number")
            }
            if condition.operator == .matchesRegex,
               (try? NSRegularExpression(pattern: condition.value)) == nil {
                return Issue(message: "Regex pattern is invalid")
            }
            return nil
        }
    }

    public static func validate(_ actions: [Action]) -> [Issue] {
        actions.compactMap { action in
            if let value = action.params[ActionParam.onConflict]?.stringValue,
               value == MoveConflictResolution.discard.rawValue, action.kind != .moveToFolder {
                return Issue(message: "Moving the incoming file to Trash is available only for Move")
            }
            if action.params["hazel_pattern_tokens"] != nil,
               let error = HazelPattern.validationError(action) { return Issue(message: error) }
            switch action.kind {
            case .moveToFolder, .copyToFolder, .syncToFolder, .makeAlias:
                if !(action.kind == .moveToFolder && action.params["hazel_sort_subfolder"]?.boolValue == true) && action.params[ActionParam.destination]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: "Destination path cannot be empty")
                }
            case .rename:
                if action.params[ActionParam.pattern]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: "Rename pattern cannot be empty")
                }
            case .addTag, .removeTag:
                if tags(in: action).isEmpty && action.params[HazelPattern.tokensKey] == nil && !(action.kind == .removeTag && action.params["remove_all_tags"]?.boolValue == true) {
                    return Issue(message: "At least one tag is required")
                }
            case .openApplication:
                if action.params[ActionParam.applicationPath]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: "Application cannot be empty")
                }
            case .runWorkflow:
                guard let path = action.params[ActionParam.workflowPath]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
                    return Issue(message: "Automator workflow requires an absolute path")
                }
            case .upload:
                do { _ = try UploadConfiguration(action: action) }
                catch { return Issue(message: "\(error)") }
            case .runHazelOSA:
                do { _ = try ActionExecutor.osaConfiguration(action) }
                catch { return Issue(message: "\(error)") }
            case .runHazelShellScript:
                if action.params[ActionParam.shellMode]?.stringValue == "external" {
                    guard let path = action.params[ActionParam.shellPath]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
                        return Issue(message: "External shell script requires an absolute path")
                    }
                    break
                }
                let shell = action.params[ActionParam.shell]?.stringValue ?? "/bin/zsh"
                guard (action.params[ActionParam.shellMode]?.stringValue ?? "embedded") == "embedded",
                      shell.hasPrefix("/"), !shell.contains("\0"),
                      let script = action.params[ActionParam.script]?.stringValue, script.utf8.count <= 1_000_000, !script.contains("\0") else {
                    return Issue(message: "Imported shell script requires an absolute interpreter path and valid source")
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
