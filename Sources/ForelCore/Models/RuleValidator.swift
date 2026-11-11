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
                    ? nil : Issue(message: String(localized: "Locked requires true or false", bundle: .forelStrings, comment: "Problem with a rule, shown in the rule editor"))
            }
            if condition.value.trimmingCharacters(in: .whitespaces).isEmpty {
                return Issue(message: String(localized: "Condition value cannot be empty", bundle: .forelStrings, comment: "Problem with a rule, shown in the rule editor"))
            }
            if condition.operator == .matchesRegex,
               (try? NSRegularExpression(pattern: condition.value)) == nil {
                return Issue(message: String(localized: "Regex pattern is invalid", bundle: .forelStrings, comment: "Problem with a rule, shown in the rule editor"))
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
                    return Issue(message: String(localized: "\(action.kind.label) requires a true or false value", bundle: .forelStrings, comment: "Problem with a rule, shown in the rule editor"))
                }
            case .moveToFolder, .copyToFolder, .syncFolders:
                if action.params[ActionParam.destination]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: String(localized: "Destination path cannot be empty", bundle: .forelStrings, comment: "Problem with a rule, shown in the rule editor"))
                }
            case .rename:
                if action.params[ActionParam.pattern]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: String(localized: "Rename pattern cannot be empty", bundle: .forelStrings, comment: "Problem with a rule, shown in the rule editor"))
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
                    return Issue(message: String(localized: "At least one tag is required", bundle: .forelStrings, comment: "Problem with a rule, shown in the rule editor"))
                }
            case .openApplication:
                if action.params[ActionParam.applicationPath]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: String(localized: "Application cannot be empty", bundle: .forelStrings, comment: "Problem with a rule, shown in the rule editor"))
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
