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
import UniformTypeIdentifiers
import Darwin
import CoreServices

public enum ConditionEvaluator {
    /// Returns true if the file at `path` satisfies the condition.
    public static func evaluate(_ condition: Condition, path: String, depth: Int? = nil, lastOpened: any LastOpenedMetadataProvider = SpotlightLastOpenedMetadata(), lastMatched: Date? = nil, now: Date = Date(), allowOCR: Bool = true) -> Bool {
        let url = URL(fileURLWithPath: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)

        switch condition.kind {
        case .peerRanking:
            guard let spec = PeerRankingCondition.decode(condition.value), let matched = try? spec.evaluate(path: path, depth: depth, lastOpened: lastOpened, now: now, allowOCR: allowOCR) else { return false }
            return condition.operator == .is ? matched : condition.operator == .isNot ? !matched : false
        case .dateComparison:
            return evaluateDateComparison(condition, path: path, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: [:]) ?? false
        case .anyFile:
            return condition.operator == .is && attrs != nil
        case .dateLastMatched:
            if condition.operator == .isBlank { return lastMatched == nil }
            if condition.operator == .isNotBlank { return lastMatched != nil }
            guard let lastMatched else { return false }
            if condition.operator == .beforeLastModified {
                guard let modified = attrs?[.modificationDate] as? Date else { return false }
                return lastMatched < modified
            }
            return matchDate(condition.operator, lastMatched, condition.value, now: now)
        case .currentTime:
            return condition.operator == .is && CurrentTimeCondition.matches(condition.value, now: now)
        case .spotlightAttribute:
            return SpotlightCondition.evaluate(condition, path: path) ?? false
        case .scriptAttribute:
            return false
        case .customTableMatch:
            return CustomTableCondition.decode(condition.value)?.evaluate(path: path, allowOCR: allowOCR)?.0 ?? false
        case .customDateMatch:
            return CustomDateCondition.decode(condition.value)?.evaluate(path: path, allowOCR: allowOCR)?.0 ?? false
        case .customTextMatch:
            return CustomTextCondition.decode(condition.value)?.evaluate(path: path, allowOCR: allowOCR)?.0 ?? false
        case .conditionGroup:
            var budget = 10_000
            var attributes: [String: JSONValue] = [:]
            return (try? evaluateGroup(condition, path: path, depth: depth, level: 0, budget: &budget, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: &attributes, allowOCR: allowOCR)) ?? false
        case .hazelScriptCondition:
            var attributes: [String: JSONValue] = [:]
            return (try? evaluateWithContext(condition, path: path, depth: depth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: &attributes, allowOCR: allowOCR)) ?? false
        case .fullName:
            return matchString(condition.operator, url.lastPathComponent, condition.value)
        case .fullNameInsensitive:
            let locale = Locale(identifier: "en_US_POSIX")
            return matchString(condition.operator,
                               url.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale),
                               condition.value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale))
        case .locked:
            guard let flags = attrs?[.immutable] as? Bool else { return false }
            switch condition.operator {
            case .is: return flags == (condition.value == "true")
            case .isNot: return flags != (condition.value == "true")
            default: return false
            }
        case .subfileCount:
            guard let attrs, let threshold = Int(condition.value), threshold >= 0 else { return false }
            let count: Int
            if attrs[.type] as? FileAttributeType == .typeDirectory {
                guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isHiddenKey], options: [.skipsHiddenFiles]) else { return false }
                count = entries.count
            } else { count = 0 }
            switch condition.operator {
            case .is: return count == threshold
            case .isNot: return count != threshold
            case .greaterThan: return count > threshold
            case .lessThan: return count < threshold
            default: return false
            }
        case .name:
            return matchName(condition.operator, url: url, condition.value)

        case .nameInsensitive:
            let stem = url.deletingPathExtension().lastPathComponent
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let value = condition.value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return matchString(condition.operator, stem, value)

        case .extension_:
            let ext = url.pathExtension.lowercased()
            let value = condition.value.trimmingPrefix(while: { $0 == "." }).lowercased()
            return matchString(condition.operator, ext, value)

        case .extensionInsensitive:
            let locale = Locale(identifier: "en_US_POSIX")
            let ext = url.pathExtension.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            let raw = condition.value.hasPrefix(".") ? String(condition.value.dropFirst()) : condition.value
            let value = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            switch condition.operator {
            case .is: return ext == value
            case .isNot: return ext != value
            default: return false
            }

        case .kind:
            guard let attrs else { return false }
            let detected = detectKind(path: path, attrs: attrs)
            switch condition.operator {
            case .is: return detected == condition.value
            case .isNot: return detected != condition.value
            default: return false
            }

        case .contentType:
            if condition.value == "hazelkind:Volume" {
                guard let isVolume = try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume else { return false }
                switch condition.operator {
                case .is: return isVolume
                case .isNot: return !isVolume
                default: return false
                }
            }
            if condition.value.hasPrefix("hazelkind:") {
                guard let kind = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription else { return false }
                let wanted = String(condition.value.dropFirst("hazelkind:".count))
                return matchHazelKind(wanted, actual: kind, operator: condition.operator) ?? false
            }
            guard let desired = UTType(condition.value),
                  let actual = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
            switch condition.operator {
            case .is: return actual.conforms(to: desired)
            case .isNot: return !actual.conforms(to: desired)
            default: return false
            }

        case .subfolderDepth:
            guard let depth, depth >= 0,
                  let target = Int(condition.value.trimmingCharacters(in: .whitespacesAndNewlines)), target >= 0 else { return false }
            switch condition.operator {
            case .is: return depth == target
            case .isNot: return depth != target
            case .greaterThan: return depth > target
            case .lessThan: return depth < target
            default: return false
            }

        case .sizeBytes:
            guard let attrs else { return false }
            let size = (attrs[.size] as? UInt64) ?? 0
            let threshold = parseSize(condition.value)
            switch condition.operator {
            case .is: return size == threshold
            case .isNot: return size != threshold
            case .greaterThan: return size > threshold
            case .lessThan: return size < threshold
            default: return false
            }

        case .tags:
            let target = condition.value.trimmingCharacters(in: .whitespaces).lowercased()
            let names = FinderTags.read(path).map { tagName($0).lowercased() }
            switch condition.operator {
            case .is: return names.contains(target)
            case .isNot: return !names.contains(target)
            case .contains: return names.contains { $0.contains(target) }
            case .doesNotContain: return !names.contains { $0.contains(target) }
            case .startsWith: return names.contains { $0.hasPrefix(target) }
            case .endsWith: return names.contains { $0.hasSuffix(target) }
            case .matchesRegex:
                guard let re = try? NSRegularExpression(pattern: condition.value) else { return false }
                return names.contains { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            default: return false
            }

        case .colorLabel:
            let target = condition.value.lowercased()
            let namedTag = FinderTags.read(path).contains { FinderTags.tagColor($0) == FinderTags.colorIndex(target) && FinderTags.tagColor($0) != nil }
            let labelNumber = try? url.resourceValues(forKeys: [.labelNumberKey]).labelNumber
            let has = namedTag || (FinderTags.colorIndex(target).map { $0 == labelNumber } ?? false)
            switch condition.operator {
            case .is: return has
            case .isNot: return !has
            default: return false
            }

        case .contents, .contentsWithoutOCR, .contentsWithOCR, .contentsWithPassword:
            return evaluateContents(condition, path: path, allowOCR: allowOCR).matched

        case .finderComment:
            do { return matchString(condition.operator, try FinderComment.read(path) ?? "", condition.value) }
            catch { return false }

        case .createdAt:
            guard let attrs else { return false }
            guard let created = attrs[.creationDate] as? Date else { return false }
            return matchDate(condition.operator, created, condition.value, now: now)

        case .dateModified:
            guard let attrs else { return false }
            guard let modified = attrs[.modificationDate] as? Date else { return false }
            return matchDate(condition.operator, modified, condition.value, now: now)

        case .dateAdded:
            guard let added = dateAdded(path: path) else { return false }
            return matchDate(condition.operator, added, condition.value, now: now)

        case .dateLastOpened:
            guard let attrs, let opened = lastOpened.lastOpened(path: path) else { return false }
            // Hazel treats an existing item without a last-used date as never opened.
            return matchLastOpened(condition, opened: opened, modified: attrs[.modificationDate] as? Date, now: now)

        case .downloadedFromWebsite:
            return matchAnyOf(condition.operator, DownloadMetadata.websiteURLs(path), condition.value)

        case .downloadedWithApp:
            guard let app = DownloadMetadata.downloadedWithApp(path) else {
                return matchAnyOf(condition.operator, [], condition.value)
            }
            return matchDownloadedApp(condition.operator, app, condition.value)

        case .rawWhereFromMetadata:
            return matchAnyOf(condition.operator, DownloadMetadata.whereFroms(path), condition.value)
        }
    }

    static func matchHazelKind(_ wanted: String, actual: String?, operator op: Operator) -> Bool? {
        guard let actual else { return nil }
        switch op {
        case .is: return actual == wanted
        case .isNot: return actual != wanted
        default: return nil
        }
    }

    static func evaluateWithContext(_ condition: Condition, path: String, depth: Int?, lastOpened: any LastOpenedMetadataProvider, lastMatched: Date? = nil, now: Date = Date(), requireAvailable: Bool = false, attributes: inout [String: JSONValue], change: ((Condition, String, Bool) throws -> Bool?)? = nil, allowOCR: Bool = true) throws -> Bool? {
        if ChangeCondition.isChange(condition) { return try change?(condition, path, false) }
        if condition.kind == .peerRanking {
            return try evaluatePeerRanking(condition, path: path, depth: depth, lastOpened: lastOpened, now: now, filters: [], allowOCR: allowOCR)
        }
        if condition.kind == .dateComparison {
            return evaluateDateComparison(condition, path: path, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: attributes)
        }
        if condition.kind == .customTextMatch {
            guard condition.operator == .is, let result = CustomTextCondition.decode(condition.value)?.evaluate(path: path, existing: attributes, allowOCR: allowOCR) else { return nil }
            if result.0 { return CustomAttributeBinding.bind(result.1, to: &attributes) }
            return result.0
        }
        if condition.kind == .customDateMatch {
            guard condition.operator == .is, let result = CustomDateCondition.decode(condition.value)?.evaluate(path: path, existing: attributes, allowOCR: allowOCR) else { return nil }
            if result.0 { return CustomAttributeBinding.bind(result.1, to: &attributes) }
            return result.0
        }
        if condition.kind == .customTableMatch {
            guard condition.operator == .is, let result = CustomTableCondition.decode(condition.value)?.evaluate(path: path, existing: attributes, allowOCR: allowOCR) else { return nil }
            if result.0 { return CustomAttributeBinding.bind(result.1, to: &attributes) }
            return result.0
        }
        if condition.kind == .scriptAttribute {
            return SpotlightCondition.evaluateScriptAttribute(condition, attributes: attributes)
        }
        if condition.kind == .conditionGroup {
            var budget = 10_000
            return try evaluateGroup(condition, path: path, depth: depth, level: 0, budget: &budget, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: &attributes, change: change, allowOCR: allowOCR)
        }
        if condition.kind == .hazelScriptCondition {
            guard let spec = HazelScriptCondition.decode(condition.value), condition.operator == .is else { throw ActionError("Invalid condition script") }
            let result = try HazelScriptConditionRunner.run(spec: spec, path: path, attributes: attributes)
            if result.matched { attributes.merge(result.attributes) { _, new in new } }
            return result.matched
        }
        if requireAvailable { return try evaluateAvailable(condition, path: path, depth: depth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: &attributes, allowOCR: allowOCR) }
        return evaluate(condition, path: path, depth: depth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, allowOCR: allowOCR)
    }

    static func evaluatePeerRanking(_ condition: Condition, path: String, depth: Int?, lastOpened: any LastOpenedMetadataProvider, now: Date, filters: [Condition], allowOCR: Bool = true) throws -> Bool? {
        guard let spec = PeerRankingCondition.decode(condition.value), let matched = try spec.evaluate(path: path, depth: depth, lastOpened: lastOpened, now: now, additionalFilters: filters, allowOCR: allowOCR) else { return nil }
        return condition.operator == .is ? matched : condition.operator == .isNot ? !matched : nil
    }

    private static func evaluateDateComparison(_ condition: Condition, path: String, lastOpened: any LastOpenedMetadataProvider, lastMatched: Date?, now: Date, attributes: [String: JSONValue]) -> Bool? {
        guard condition.operator == .is, let spec = DateComparisonCondition.decode(condition.value), spec.isValid,
              let file = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        func resolve(_ source: DateComparisonCondition.DateSource, attribute: String) -> Date? {
            switch source {
            case .created: return file[.creationDate] as? Date
            case .modified: return file[.modificationDate] as? Date
            case .added: return dateAdded(path: path)
            case .lastOpened: return lastOpened.lastOpened(path: path)
            case .lastMatched: return lastMatched
            case .current: return now
            case .fixed: return DateComparisonCondition.parseFixed(spec.fixedDate)
            case .custom:
                guard case .number(let seconds) = attributes[attribute]?["__forelDate"], seconds.isFinite else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }
        }
        guard let left = resolve(spec.left, attribute: spec.leftAttribute) else { return nil }
        let right = [.before, .after, .sameDay].contains(spec.relation) ? resolve(spec.right, attribute: spec.rightAttribute) : nil
        return spec.compare(left, right: right, now: now, calendar: .current)
    }

    private static func evaluateGroup(_ condition: Condition, path: String, depth: Int?, level: Int, budget: inout Int, lastOpened: any LastOpenedMetadataProvider, lastMatched: Date?, now: Date, attributes: inout [String: JSONValue], change: ((Condition, String, Bool) throws -> Bool?)? = nil, negated: Bool = false, allowOCR: Bool = true) throws -> Bool? {
        guard level < 16, budget > 0, condition.operator == .is, let group = ConditionGroup.decode(condition.value),
              !group.conditions.isEmpty, group.conditions.count <= 1000 else { return nil }
        guard group.conditions.filter({ $0.kind == .peerRanking }).count <= 1 else { throw ActionError("Only one peer ranking condition is supported in a group") }
        budget -= 1
        let fileURL = URL(fileURLWithPath: path)
        let paths: [String]
        switch group.target {
        case .current: paths = [path]
        case .parent: paths = [fileURL.deletingLastPathComponent().path]
        case .anyChild, .allChildren, .anySibling, .allSiblings:
            let children = group.target == .anyChild || group.target == .allChildren
            let directory = children ? fileURL : fileURL.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
                  items.count <= 10_000 else { return nil }
            paths = items.map(\.path).filter { children || $0 != path }.sorted()
        }
        let candidateDepth: Int?
        switch group.target {
        case .current, .anySibling, .allSiblings: candidateDepth = depth
        case .parent: candidateDepth = depth.flatMap { $0 > 0 ? $0 - 1 : nil }
        case .anyChild, .allChildren: candidateDepth = depth.flatMap { $0 < Int.max ? $0 + 1 : nil }
        }
        var results: [Bool?] = []
        let originalAttributes = attributes
        var successfulAttributes = attributes
        for candidate in paths {
            var matches: [Bool?] = []
            var candidateAttributes = originalAttributes
            for (childIndex, child) in group.conditions.enumerated() {
                guard budget > 0 else { return nil }
                budget -= 1
                let result: Bool?
                var branchAttributes = group.match == .all ? candidateAttributes : originalAttributes
                if ChangeCondition.isChange(child) {
                    result = try change?(child, candidate, negated != (group.match == .none))
                } else if child.kind == .peerRanking {
                    let filters = group.match == .all ? group.conditions.enumerated().filter { $0.offset != childIndex && $0.element.kind != .peerRanking }.map(\.element) : []
                    result = try evaluatePeerRanking(child, path: candidate, depth: candidateDepth, lastOpened: lastOpened, now: now, filters: filters, allowOCR: allowOCR)
                } else if child.kind == .conditionGroup {
                    result = try evaluateGroup(child, path: candidate, depth: candidateDepth, level: level + 1, budget: &budget, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: &branchAttributes, change: change, negated: negated != (group.match == .none), allowOCR: allowOCR)
                } else {
                    result = try evaluateAvailable(child, path: candidate, depth: candidateDepth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: &branchAttributes, allowOCR: allowOCR)
                }
                matches.append(result)
                if result == true && group.match != .none { candidateAttributes = branchAttributes }
                if (group.match == .all && result == false) || (group.match != .all && result == true) { break }
            }
            let candidateResult = aggregate(matches, mode: group.match)
            results.append(candidateResult)
            if candidateResult == true { successfulAttributes = candidateAttributes }
            switch group.target {
            case .current, .parent:
                if candidateResult == true { attributes = successfulAttributes }
                return candidateResult
            case .anyChild, .anySibling:
                if candidateResult == true { attributes = successfulAttributes; return true }
            case .allChildren, .allSiblings:
                if candidateResult == false { return false }
            }
        }
        switch group.target {
        case .current, .parent: return results.first ?? nil
        case .anyChild, .anySibling: return aggregate(results, mode: .any)
        case .allChildren, .allSiblings:
            if paths.isEmpty { return false }
            let result = aggregate(results, mode: .all)
            if result == true { attributes = successfulAttributes }
            return result
        }
    }

    private static func aggregate(_ values: [Bool?], mode: ConditionGroup.Match) -> Bool? {
        switch mode {
        case .any:
            if values.contains(where: { $0 == true }) { return true }
            return values.contains(where: { $0 == nil }) ? nil : false
        case .all:
            if values.contains(where: { $0 == false }) { return false }
            return values.contains(where: { $0 == nil }) ? nil : true
        case .none:
            return aggregate(values, mode: .any).map { !$0 }
        }
    }

    /// Preserve unknown as unknown: in particular NOT must not turn a failed
    /// content extraction or inaccessible metadata into a positive match.
    private static func evaluateAvailable(_ condition: Condition, path: String, depth: Int?, lastOpened: any LastOpenedMetadataProvider, lastMatched: Date?, now: Date, attributes: inout [String: JSONValue], allowOCR: Bool = true) throws -> Bool? {
        // Table evaluation validates the same single snapshot that it uses;
        // a separate validator read here could observe a different file.
        if condition.kind == .customTableMatch {
            return try evaluateWithContext(condition, path: path, depth: depth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: &attributes, allowOCR: allowOCR)
        }
        guard condition.kind.validOperators.contains(condition.operator), RuleValidator.validate([condition]).isEmpty,
              FileManager.default.isReadableFile(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        if condition.operator.usesRelativeDateValue, cutoffDate(condition.value) == nil { return nil }
        if [.before, .after].contains(condition.operator), parseDate(condition.value) == nil { return nil }
        switch condition.kind {
        case .hazelScriptCondition, .customTableMatch, .customDateMatch, .customTextMatch, .dateComparison, .peerRanking:
            return try evaluateWithContext(condition, path: path, depth: depth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: &attributes, allowOCR: allowOCR)
        case .spotlightAttribute:
            return SpotlightCondition.evaluate(condition, path: path)
        case .scriptAttribute:
            return SpotlightCondition.evaluateScriptAttribute(condition, attributes: attributes)
        case .contentsWithPassword:
            return evaluatePasswordContents(condition, path: path, allowOCR: allowOCR)
        case .contents, .contentsWithoutOCR, .contentsWithOCR:
            let extraction = ContentExtractor.extract(path: path, allowOCR: allowOCR, useOCR: condition.kind != .contentsWithoutOCR, forceOCR: condition.kind == .contentsWithOCR)
            guard let text = extraction.text else { return nil }
            return matchString(condition.operator, text, condition.value)
        case .finderComment:
            do { return matchString(condition.operator, try FinderComment.read(path) ?? "", condition.value) }
            catch { return nil }
        case .createdAt: guard attrs[.creationDate] is Date else { return nil }
        case .dateModified: guard attrs[.modificationDate] is Date else { return nil }
        case .dateAdded:
            guard (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate) != nil else { return nil }
        case .locked: guard attrs[.immutable] is Bool else { return nil }
        case .subfolderDepth: guard depth != nil else { return nil }
        case .subfileCount:
            if attrs[.type] as? FileAttributeType == .typeDirectory,
               (try? FileManager.default.contentsOfDirectory(atPath: path)) == nil { return nil }
        case .contentType:
            let url = URL(fileURLWithPath: path)
            if condition.value == "hazelkind:Volume" {
                guard (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) != nil else { return nil }
            } else if condition.value.hasPrefix("hazelkind:") {
                guard (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription) != nil else { return nil }
            } else {
                guard (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) != nil else { return nil }
            }
        case .dateLastOpened:
            guard lastOpened.lastOpened(path: path) != nil else { return nil }
        case .dateLastMatched:
            if condition.operator != .isBlank && condition.operator != .isNotBlank && lastMatched == nil { return nil }
            if condition.operator == .beforeLastModified && !(attrs[.modificationDate] is Date) { return nil }
        case .downloadedFromWebsite:
            guard !DownloadMetadata.websiteURLs(path).isEmpty else { return nil }
        case .downloadedWithApp:
            guard DownloadMetadata.downloadedWithApp(path) != nil else { return nil }
        case .rawWhereFromMetadata:
            guard !DownloadMetadata.whereFroms(path).isEmpty else { return nil }
        default: break
        }
        return evaluate(condition, path: path, depth: depth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, allowOCR: allowOCR)
    }

    static func matchLastOpened(_ condition: Condition, opened: Date, modified: Date?, now: Date = Date()) -> Bool {
        if condition.operator == .afterLastModified {
            guard let modified else { return false }
            return opened > modified
        }
        return matchDate(condition.operator, opened, condition.value, now: now)
    }

    /// Evaluates a `contents` condition, returning the match result together
    /// with which extraction strategy was used and any short reason. The Dry Run
    /// uses the extra detail to explain what was read; `evaluate` discards it.
    /// When no text can be extracted every operator is `false`, so a rule never
    /// matches on content it could not read (including the negative operators).
    static func evaluateContents(_ condition: Condition, path: String, allowOCR: Bool = true) -> (matched: Bool, strategy: ContentStrategy, message: String?) {
        if condition.kind == .contentsWithPassword {
            return (evaluatePasswordContents(condition, path: path, allowOCR: allowOCR) ?? false, .none, "Uses a Keychain password reference.")
        }
        let result = ContentExtractor.extract(path: path, allowOCR: allowOCR, useOCR: condition.kind != .contentsWithoutOCR, forceOCR: condition.kind == .contentsWithOCR)
        if let text = result.text {
            return (matchString(condition.operator, text, condition.value), result.strategy, result.message)
        }
        // Nothing readable in-process. For formats macOS indexes but we can't
        // read directly (e.g. legacy .xls), fall back to Spotlight — which can
        // only confirm a `contains` match, never a negative operator.
        if [.contains, .containsInsensitive].contains(condition.operator),
           !condition.value.isEmpty,
           ContentExtractor.supportsSpotlightFallback(path: path),
           ContentExtractor.spotlightContains(path: path, term: condition.value) {
            return (true, .spotlight, nil)
        }
        return (false, result.strategy, result.message)
    }

    static func evaluatePasswordContents(_ condition: Condition, path: String, allowOCR: Bool = true, lookup: (String) -> String? = PDFPasswordStore.password) -> Bool? {
        guard (path as NSString).pathExtension.lowercased() == "pdf", let spec = PasswordContentCondition.decode(condition.value),
              spec.referenceIsValid, let password = lookup(spec.credentialID) else { return nil }
        let result = ContentExtractor.extract(path: path, allowOCR: allowOCR, pdfPassword: password)
        guard let text = result.text else { return nil }
        return matchString(condition.operator, text, spec.operand)
    }

    /// True if any value in `haystacks` satisfies the operator against
    /// `needle`. `is not`/`does not contain` are defined as the exact
    /// negation of `is`/`contains` across the whole list (same pattern as the
    /// `tags` condition above), which gives the right behavior when the list
    /// is empty — e.g. a file with no download metadata at all: every
    /// positive operator is `false`, every negative operator is `true`.
    private static func matchAnyOf(_ operator_: Operator, _ haystacks: [String], _ needle: String) -> Bool {
        switch operator_ {
        case .is: return haystacks.contains { $0 == needle }
        case .isNot: return !haystacks.contains { $0 == needle }
        case .contains: return haystacks.contains { $0.contains(needle) }
        case .doesNotContain: return !haystacks.contains { $0.contains(needle) }
        case .startsWith: return haystacks.contains { $0.hasPrefix(needle) }
        case .endsWith: return haystacks.contains { $0.hasSuffix(needle) }
        case .matchesRegex:
            guard let re = try? NSRegularExpression(pattern: needle) else { return false }
            return haystacks.contains { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        default:
            return false
        }
    }

    private static func matchDownloadedApp(_ operator_: Operator, _ actual: String, _ expected: String) -> Bool {
        switch operator_ {
        case .is:
            return appNamesMatch(actual: actual, expected: expected)
        case .isNot:
            return !appNamesMatch(actual: actual, expected: expected)
        default:
            return matchAnyOf(operator_, [actual], expected)
        }
    }

    private static func appNamesMatch(actual: String, expected: String) -> Bool {
        actual == expected || actual == quarantineAgentAlias(forAppName: expected)
    }

    private static func quarantineAgentAlias(forAppName name: String) -> String {
        if name.hasPrefix("Google ") {
            return String(name.dropFirst("Google ".count))
        }
        return name
    }

    /// macOS "Date Added" (when the file was added to its current folder). Not
    /// exposed by `stat`/`FileManager`, so it is read via `getattrlist` with
    /// `ATTR_CMN_ADDEDTIME`. Returns `nil` if the volume does not track it.
    private static func dateAdded(path: String) -> Date? {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)

        var buf = [UInt8](repeating: 0, count: 4 + 16)
        let rc = buf.withUnsafeMutableBytes { rawBuf in
            getattrlist(path, &attrList, rawBuf.baseAddress, rawBuf.count, 0)
        }
        guard rc == 0 else { return nil }

        let secs = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        if secs == 0 { return nil }
        let nsecs = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: Int64.self) }
        return Date(timeIntervalSince1970: Double(secs) + Double(nsecs) / 1_000_000_000)
    }

    /// Matches a file timestamp against a date operator, keyed on the operator
    /// (not the condition kind) so it is reusable by any date condition.
    /// `before`/`after` take a calendar date ("YYYY-MM-DD"); `older_than`/
    /// `within_last` take a relative duration ("30 days"). Invalid values never match.
    private static func matchDate(_ operator_: Operator, _ fileDate: Date, _ value: String, now: Date = Date()) -> Bool {
        switch operator_ {
        case .beforeToday:
            return fileDate < Calendar.current.startOfDay(for: now)
        case .beforeThisWeek, .beforeThisMonth, .notThisWeek, .notThisMonth:
            let component: Calendar.Component = (operator_ == .beforeThisWeek || operator_ == .notThisWeek) ? .weekOfYear : .month
            guard let period = Calendar.current.dateInterval(of: component, for: now) else { return false }
            if operator_ == .beforeThisWeek || operator_ == .beforeThisMonth { return fileDate < period.start }
            return fileDate < period.start || fileDate >= period.end
        case .before:
            guard let day = parseDate(value) else { return false }
            return fileDate < day
        case .after:
            guard let day = parseDate(value), let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return false }
            return fileDate >= nextDay
        case .olderThan:
            guard let cutoff = cutoffDate(value, now: now) else { return false }
            return fileDate < cutoff
        case .withinLast:
            guard let cutoff = cutoffDate(value, now: now) else { return false }
            return fileDate >= cutoff
        case .hazelWithinLast, .hazelNotWithinLast:
            guard let cutoff = hazelCutoffDate(value, now: now) else { return false }
            let within = fileDate >= cutoff && fileDate <= now
            return operator_ == .hazelWithinLast ? within : !within
        default:
            return false
        }
    }

    /// Parses "YYYY-MM-DD" into midnight local time on that day.
    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    /// Parses a relative duration ("2 hours", "30 days", "2 weeks", "6 months", "1 years")
    /// into the cutoff instant `now - duration`. Months/years use calendar arithmetic.
    private static func cutoffDate(_ value: String, now: Date = Date()) -> Date? {
        let s = value.trimmingCharacters(in: .whitespaces)
        guard let splitIndex = s.firstIndex(where: { !$0.isNumber }) else { return nil }
        let numPart = String(s[s.startIndex..<splitIndex]).trimmingCharacters(in: .whitespaces)
        let unitPart = String(s[splitIndex...]).trimmingCharacters(in: .whitespaces).lowercased()
        guard let n = Int(numPart) else { return nil }

        var component: Calendar.Component
        switch unitPart {
        case "minute", "minutes": component = .minute
        case "hour", "hours": component = .hour
        case "day", "days": component = .day
        case "week", "weeks": component = .weekOfYear
        case "month", "months": component = .month
        case "year", "years": component = .year
        default: return nil
        }
        return Calendar.current.date(byAdding: component, value: -n, to: now)
    }

    /// Hazel's `time` units use fixed seconds; its calendar months use the
    /// calendar. Preserve that distinction across daylight-saving transitions.
    static func hazelCutoffDate(_ value: String, now: Date, calendar: Calendar = .current) -> Date? {
        let parts = value.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let amount = Int(parts[0]), (0...1_000_000).contains(amount) else { return nil }
        let unit = parts[1].lowercased()
        let scale: TimeInterval
        switch unit {
        case "minute", "minutes": scale = 60
        case "hour", "hours": scale = 3_600
        case "day", "days": scale = 86_400
        case "week", "weeks": scale = 604_800
        case "month", "months": return calendar.date(byAdding: .month, value: -amount, to: now)
        case "year", "years": return calendar.date(byAdding: .year, value: -amount, to: now)
        default: return nil
        }
        return now.addingTimeInterval(-Double(amount) * scale)
    }

    /// Classifies a file into a Hazel-style kind string based on its extension.
    private static func detectKind(path: String, attrs: [FileAttributeKey: Any]) -> String {
        let url = URL(fileURLWithPath: path)
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        if isDir {
            return url.pathExtension.lowercased() == "app" ? "application" : "folder"
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "svg", "heic", "heif", "raw", "cr2", "cr3", "nef", "arw", "dng":
            return "image"
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm", "mpg", "mpeg":
            return "movie"
        case "mp3", "aac", "flac", "wav", "aiff", "aif", "m4a", "ogg", "wma", "opus":
            return "music"
        case "pdf":
            return "pdf"
        case "txt", "md", "markdown", "rtf", "rst", "log":
            return "text"
        case "ppt", "pptx", "key", "odp":
            return "presentation"
        case "zip", "tar", "gz", "bz2", "7z", "rar", "xz", "zst", "tgz", "tbz", "cab":
            return "archive"
        case "dmg", "iso", "img", "sparseimage", "sparsebundle":
            return "disk_image"
        default:
            return "document"
        }
    }

    private static func matchString(_ operator_: Operator, _ haystack: String, _ needle: String) -> Bool {
        switch operator_ {
        case .isBlank: return haystack.isEmpty
        case .isNotBlank: return !haystack.isEmpty
        case .is: return haystack == needle
        case .isNot: return haystack != needle
        case .contains: return haystack.contains(needle)
        case .containsInsensitive:
            return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil
        case .doesNotContain: return !haystack.contains(needle)
        case .startsWith: return haystack.hasPrefix(needle)
        case .endsWith: return haystack.hasSuffix(needle)
        case .matchesRegex:
            guard let re = try? NSRegularExpression(pattern: needle) else { return false }
            return re.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
        default:
            return false
        }
    }

    /// Name conditions traditionally operate on the extensionless stem, but
    /// exact comparisons also accept the complete filename. This keeps rules
    /// such as `Name is invoice` working while allowing exclusions copied from
    /// Finder, such as `Name is not Desktop.ini`, to compare the intended name.
    private static func matchName(_ operator_: Operator, url: URL, _ needle: String) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        let fullName = url.lastPathComponent
        switch operator_ {
        case .is:
            return stem == needle || fullName == needle
        case .isNot:
            return stem != needle && fullName != needle
        default:
            return matchString(operator_, stem, needle)
        }
    }

    /// Parses a size threshold into bytes. Accepts a plain number ("5242880")
    /// or a number with a unit suffix ("5 MB", "100kb"). Unitless values are bytes.
    private static func parseSize(_ value: String) -> UInt64 {
        let s = value.trimmingCharacters(in: .whitespaces)
        guard let splitIndex = s.firstIndex(where: { !$0.isNumber && $0 != "." }) else {
            return clampedBytes(Double(s) ?? 0)
        }
        let numPart = String(s[s.startIndex..<splitIndex]).trimmingCharacters(in: .whitespaces)
        let unitPart = String(s[splitIndex...]).trimmingCharacters(in: .whitespaces).lowercased()
        let n = Double(numPart) ?? 0
        let multiplier: Double
        switch unitPart {
        case "kb": multiplier = 1024
        case "mb": multiplier = 1024 * 1024
        case "gb": multiplier = 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return clampedBytes(n * multiplier)
    }

    /// A checked `UInt64(...)` conversion traps on values that don't fit
    /// (a very long digit string parses to a huge or infinite `Double`), so
    /// an oversized threshold saturates instead of crashing the rule run.
    private static func clampedBytes(_ value: Double) -> UInt64 {
        guard value > 0 else { return 0 }
        guard value < Double(UInt64.max) else { return .max }
        return UInt64(value)
    }

    private static func tagName(_ tag: String) -> String {
        let name = tag.split(separator: "\n").first.map(String.init) ?? tag
        return name.trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    func trimmingPrefix(while predicate: (Character) -> Bool) -> String {
        var s = Substring(self)
        while let first = s.first, predicate(first) { s = s.dropFirst() }
        return String(s)
    }
}
