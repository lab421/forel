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
import CryptoKit

public struct ScopedPath: Sendable {
    public let path: String
    public let depth: Int

    public init(path: String, depth: Int) {
        self.path = path
        self.depth = depth
    }
}

public struct RulePreview: Sendable {
    public let ruleId: String
    public let ruleName: String
    public let conditions: [ConditionPreview]
    public let actions: [ActionPreview]

    public init(ruleId: String, ruleName: String, conditions: [ConditionPreview], actions: [ActionPreview]) {
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.conditions = conditions
        self.actions = actions
    }
}

public struct ConditionPreview: Sendable {
    public let kind: ConditionKind
    public let operator_: Operator
    public let value: String
    public let matched: Bool
    public let known: Bool
    /// Optional secondary line shown in the Dry Run — e.g. for `contents`, which
    /// extraction strategy was used ("PDF text") or why nothing was read.
    public let detail: String?

    public init(kind: ConditionKind, operator_: Operator, value: String, matched: Bool, detail: String? = nil, known: Bool = true) {
        self.kind = kind
        self.operator_ = operator_
        self.value = value
        self.matched = matched
        self.known = known
        self.detail = detail
    }
}

public struct ActionPreview: Hashable, Sendable {
    public let kind: ActionKind
    public let description: String
    public let sourcePath: String
    public let targetPath: String?
    public let status: DryRunStatus
    public let warning: String?

    public init(kind: ActionKind, description: String, sourcePath: String, targetPath: String?, status: DryRunStatus, warning: String? = nil) {
        self.kind = kind
        self.description = description
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.status = status
        self.warning = warning
    }
}

public struct FilePreview: Sendable {
    public let path: String
    public let name: String
    public let rules: [RulePreview]

    public init(path: String, name: String, rules: [RulePreview]) {
        self.path = path
        self.name = name
        self.rules = rules
    }
}

public struct PreviewResult: Sendable {
    public let filesScanned: Int
    public let matches: [FilePreview]
    public let matchLimit: Int?
    public let reachedMatchLimit: Bool

    public init(filesScanned: Int, matches: [FilePreview], matchLimit: Int? = nil, reachedMatchLimit: Bool = false) {
        self.filesScanned = filesScanned
        self.matches = matches
        self.matchLimit = matchLimit
        self.reachedMatchLimit = reachedMatchLimit
    }
}

public enum RuleEngine {
    /// Evaluates all enabled rules against `path` and runs matching ones.
    /// Returns the names of rules that matched and the history entries
    /// produced by their actions (grouped under `batchId`).
    ///
    /// Shares its per-action decision (target path, skip/conflict/run
    /// status) with `previewFile` by going through `ActionExecutor.plan`
    /// first, then acting on it — so Dry Run, Run Now, and the watcher can
    /// never see a different outcome for the same file and rules.
    public static func run(path: String, depth: Int, rules: [Rule], batchId: String, root: String? = nil, isPro: Bool = true, platform: any ActionPlatform = MacActionPlatform(), lastOpened: any LastOpenedMetadataProvider = SpotlightLastOpenedMetadata(), matchState: (any HazelMatchStateStore)? = nil, counterStore: (any FolderCounterStore)? = nil, uploadServers: [UploadServer] = [], now: Date = Date(), forceRunPreviouslyMatched: Bool = false, beforeAction: (() throws -> Void)? = nil) -> (matched: [String], history: [HistoryEntry]) {
        let result = runWithTraversal(path: path, depth: depth, rules: rules, batchId: batchId, root: root, isPro: isPro, platform: platform, lastOpened: lastOpened, matchState: matchState, counterStore: counterStore, uploadServers: uploadServers, now: now, forceRunPreviouslyMatched: forceRunPreviouslyMatched, beforeAction: beforeAction)
        return (result.matched, result.history)
    }

    public static func runWithTraversal(path: String, depth: Int, rules: [Rule], batchId: String, root: String? = nil, isPro: Bool = true, platform: any ActionPlatform = MacActionPlatform(), lastOpened: any LastOpenedMetadataProvider = SpotlightLastOpenedMetadata(), matchState: (any HazelMatchStateStore)? = nil, counterStore: (any FolderCounterStore)? = nil, uploadServers: [UploadServer] = [], now: Date = Date(), forceRunPreviouslyMatched: Bool = false, peerRecheckOnly: Bool = false, beforeAction: (() throws -> Void)? = nil, onRecurse: ((String) -> Void)? = nil) -> (matched: [String], history: [HistoryEntry], recurses: Bool) {
        guard !SystemFileFilter.isExcluded((path as NSString).lastPathComponent), !FileReadiness.isMarkedBusy(path) else {
            return ([], [], false)
        }

        struct PendingFile {
            let path: String
            let depth: Int
            let startRuleIndex: Int
            let blockedRuleIds: Set<String>
        }

        var matched: [String] = []
        var history: [HistoryEntry] = []
        var recurses = false
        var pending = [PendingFile(path: path, depth: depth, startRuleIndex: 0, blockedRuleIds: [])]
        // A folder is only walked for busy items once a rule actually wants
        // to act on it; doing so for every scanned entry would read the whole
        // tree under each one.
        var checkedBusyContents = false

        while !pending.isEmpty {
            let target = pending.removeFirst()
            var currentPath = target.path
            var currentDepth = target.depth
            var blockedRuleIds = target.blockedRuleIds

            for ruleIndex in target.startRuleIndex..<rules.count {
                let rule = rules[ruleIndex]
                guard !blockedRuleIds.contains(rule.id) else { continue }
                guard rule.enabled, (isPro || FreePlan.requiredFeature(for: rule) == nil), ruleInScope(rule, depth: currentDepth) else { continue }
                if peerRecheckOnly && !isPeerSensitive(rule) && !rule.isHazelImported { continue }
                if let error = rule.importError {
                    history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name,
                                                actionKind: .importError, originalPath: currentPath, resultPath: currentPath,
                                                undo: Undo.none.toJSON(), reversible: false, status: .failed,
                                                message: "Incomplete Hazel import: \(error)"))
                    break
                }
                let hasChange = ChangeCondition.containsChange(rule.conditions)
                let hasDidChange = ChangeCondition.containsDidChange(rule.conditions, negated: rule.conditionMatch == .none)
                let tracksState = rule.isHazelImported || isTimeSensitive(rule) || isPeerSensitive(rule) || hasChange
                let itemKey = tracksState ? matchState?.itemKey(path: currentPath) : nil
                let signature = conditionSignature(rule)
                let oldState: HazelMatchState?
                do { oldState = try itemKey.flatMap { try matchState?.state(ruleId: rule.id, itemKey: $0) } }
                catch {
                    history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name, actionKind: .importError, originalPath: currentPath, resultPath: currentPath, undo: Undo.none.toJSON(), reversible: false, status: .failed, message: "Could not read rule match state: \(error)"))
                    break
                }
                var conditionAttributes: [String: JSONValue] = [:]
                let tracker = ChangeTracker(state: matchState, ruleId: rule.id)
                if peerRecheckOnly && !isPeerSensitive(rule) && rule.isHazelImported && hasScriptCondition(rule) {
                    history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name, actionKind: .importError, originalPath: currentPath, resultPath: currentPath, undo: Undo.none.toJSON(), reversible: false, status: .skipped, message: "Peer recheck needs an earlier rule’s script condition; run rules now to evaluate it."))
                    break
                }
                do {
                    if hasChange && tracker == nil { throw ActionError("Change conditions require a persistent watched-folder state store") }
                    let matched = try ruleMatches(rule, path: currentPath, depth: currentDepth, lastOpened: lastOpened, lastMatched: oldState?.lastMatched, now: now, attributes: &conditionAttributes, tracker: tracker, allowOCR: isPro)
                    if let tracker { try tracker.commit(tracker.seeds) }
                    guard matched else {
                        if let tracker { try tracker.commit(tracker.stableUpdates) }
                        if tracksState, let itemKey, let oldState, oldState.matched {
                            try matchState?.setState(HazelMatchState(conditionSignature: signature, matched: false, lastMatched: oldState.lastMatched), ruleId: rule.id, itemKey: itemKey)
                        }
                        continue
                    }
                } catch {
                    history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name, actionKind: .runHazelOSA, originalPath: currentPath, resultPath: currentPath, undo: Undo.none.toJSON(), reversible: false, status: .failed, message: "Condition failed: \(error)"))
                    break
                }
                if peerRecheckOnly && !isPeerSensitive(rule) {
                    if rule.actions.allSatisfy({ $0.kind == .hazelContinue }) && !rule.actions.isEmpty { continue }
                    if rule.actions.contains(where: { $0.kind == .hazelContinue }) {
                        history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name, actionKind: .importError, originalPath: currentPath, resultPath: currentPath, undo: Undo.none.toJSON(), reversible: false, status: .skipped, message: "Peer recheck needs an earlier continuing rule’s actions; run rules now to evaluate them."))
                    }
                    break
                }
                if !hasDidChange, !forceRunPreviouslyMatched, tracksState, oldState?.matched == true, oldState?.conditionSignature == signature,
                   (rule.isHazelImported || oldState?.fingerprint == FileFingerprint.current(currentPath)) {
                    if oldState?.recurses == true, let onRecurse, isRealDirectory(currentPath) {
                        onRecurse(currentPath)
                        recurses = true
                    }
                    continue
                }
                if !checkedBusyContents {
                    checkedBusyContents = true
                    if FileReadiness.containsBusyItem(path) { return ([], [], false) }
                }

                let result = runActions(rule, path: currentPath, batchId: batchId, platform: platform, watchedRoot: root, counterStore: counterStore, uploadServers: uploadServers, initialAttributes: conditionAttributes, beforeAction: beforeAction, onRecurse: onRecurse)
                history.append(contentsOf: result.history)
                recurses = recurses || result.recurses
                matched.append(rule.name)
                if tracksState, let itemKey, result.history.allSatisfy({ $0.status == .applied || $0.status == .skipped }) {
                    do {
                        if let tracker { try tracker.commit(tracker.updates) }
                        try matchState?.setState(HazelMatchState(conditionSignature: signature, matched: true, lastMatched: now, recurses: result.recurses, fingerprint: FileFingerprint.current(result.finalPath)), ruleId: rule.id, itemKey: itemKey)
                    }
                    catch { history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name, actionKind: .importError, originalPath: currentPath, resultPath: result.finalPath, undo: Undo.none.toJSON(), reversible: false, status: .failed, message: "Could not save rule match state: \(error)")) }
                }

                for copiedPath in (rule.isHazelImported && !result.continues ? [] : result.copiedPaths) {
                    let copiedDepth: Int
                    if let root {
                        guard let depth = pathDepth(root: root, path: copiedPath) else { continue }
                        copiedDepth = depth
                    } else {
                        copiedDepth = currentDepth
                    }
                    pending.append(
                        PendingFile(
                            path: copiedPath,
                            depth: copiedDepth,
                            startRuleIndex: ruleIndex + 1,
                            blockedRuleIds: blockedRuleIds.union([rule.id])
                        )
                    )
                }

                // A terminal action (move/trash/delete) takes the file out of
                // this location — even if it didn't actually run (e.g. a
                // skipped/blocked conflict), later actions in this rule and
                // later rules in this pass were written assuming it had, so
                // stop here regardless of whether it ran.
                if result.isTerminal || (rule.isHazelImported && (!result.continues || (root != nil && pathDepth(root: root!, path: result.finalPath) == nil))) { break }

                // A non-terminal action (e.g. rename) can still change the
                // file's path; follow it so the next rule in the chain sees
                // where the file actually is now, not where it used to be.
                if result.finalPath != currentPath {
                    currentPath = result.finalPath
                    blockedRuleIds.insert(rule.id)
                    if let root, let depth = pathDepth(root: root, path: currentPath) {
                        currentDepth = depth
                    }
                }
            }
        }
        return (matched, history, recurses)
    }

    public static func previewFile(path: String, depth: Int, rules: [Rule], root: String? = nil, isPro: Bool = true, lastOpened: any LastOpenedMetadataProvider = SpotlightLastOpenedMetadata(), matchState: (any HazelMatchStateStore)? = nil, counterStore: (any FolderCounterStore)? = nil, uploadServers: [UploadServer] = [], now: Date = Date(), onRecurse: ((String) -> Void)? = nil) -> FilePreview? {
        guard !SystemFileFilter.isExcluded((path as NSString).lastPathComponent), !FileReadiness.isMarkedBusy(path) else {
            return nil
        }

        struct PendingFile {
            let path: String
            let depth: Int
            let startRuleIndex: Int
            let blockedRuleIds: Set<String>
        }

        var matchedRules: [RulePreview] = []
        var pending = [PendingFile(path: path, depth: depth, startRuleIndex: 0, blockedRuleIds: [])]
        var checkedBusyContents = false

        while !pending.isEmpty {
            let target = pending.removeFirst()
            var currentPath = target.path
            var currentDepth = target.depth
            var blockedRuleIds = target.blockedRuleIds

            for ruleIndex in target.startRuleIndex..<rules.count {
                let rule = rules[ruleIndex]
                guard !blockedRuleIds.contains(rule.id) else { continue }
                guard rule.enabled, (isPro || FreePlan.requiredFeature(for: rule) == nil), ruleInScope(rule, depth: currentDepth) else { continue }
                if let error = rule.importError {
                    matchedRules.append(RulePreview(ruleId: rule.id, ruleName: rule.name, conditions: [],
                        actions: [ActionPreview(kind: .importError, description: "Incomplete Hazel import: \(error)",
                                                sourcePath: currentPath, targetPath: nil, status: .blocked)]))
                    break
                }
                var conditionAttributes: [String: JSONValue] = [:]
                let tracker = ChangeTracker(state: matchState, ruleId: rule.id)
                let conditions: [ConditionPreview]
                let oldState: HazelMatchState?
                do {
                    oldState = try matchState.flatMap { try $0.state(ruleId: rule.id, itemKey: $0.itemKey(path: currentPath)) }
                    conditions = try conditionPreviews(rule, path: currentPath, depth: currentDepth, lastOpened: lastOpened, lastMatched: oldState?.lastMatched, now: now, attributes: &conditionAttributes, tracker: tracker, allowOCR: isPro)
                }
                catch {
                    matchedRules.append(RulePreview(ruleId: rule.id, ruleName: rule.name, conditions: [], actions: [ActionPreview(kind: .runHazelOSA, description: "Condition failed: \(error)", sourcePath: currentPath, targetPath: nil, status: .blocked)]))
                    break
                }
                guard conditionResultsMatch(conditions.map { $0.known ? $0.matched : nil }, rule.conditionMatch) else { continue }
                if !ChangeCondition.containsDidChange(rule.conditions, negated: rule.conditionMatch == .none), rule.isHazelImported, oldState?.matched == true, oldState?.conditionSignature == conditionSignature(rule) {
                    if oldState?.recurses == true, let onRecurse, isRealDirectory(currentPath) { onRecurse(currentPath) }
                    matchedRules.append(RulePreview(ruleId: rule.id, ruleName: rule.name, conditions: conditions,
                        actions: [ActionPreview(kind: .ignore, description: "Already matched; waiting for conditions to change", sourcePath: currentPath, targetPath: nil, status: .wouldSkip)]))
                    continue
                }
                if !checkedBusyContents {
                    checkedBusyContents = true
                    if FileReadiness.containsBusyItem(path) { return nil }
                }

                let result = previewActions(rule, path: currentPath, watchedRoot: root, counterStore: counterStore, uploadServers: uploadServers, initialAttributes: conditionAttributes, onRecurse: onRecurse)
                matchedRules.append(
                    RulePreview(
                        ruleId: rule.id,
                        ruleName: rule.name,
                        conditions: conditions,
                        actions: result.actions
                    )
                )

                for copiedPath in (rule.isHazelImported && !result.continues ? [] : result.copiedPaths) {
                    pending.append(
                        PendingFile(
                            path: copiedPath,
                            depth: currentDepth,
                            startRuleIndex: ruleIndex + 1,
                            blockedRuleIds: blockedRuleIds.union([rule.id])
                        )
                    )
                }

                if result.isTerminal || (rule.isHazelImported && (!result.continues || (root != nil && pathDepth(root: root!, path: result.finalPath) == nil))) { break }

                if result.finalPath != currentPath {
                    currentPath = result.finalPath
                    blockedRuleIds.insert(rule.id)
                    // Preview is intentionally pure: when simulating a rename
                    // to a path that does not exist yet, keep the current depth.
                    currentDepth = target.depth
                }
            }
        }

        guard !matchedRules.isEmpty else { return nil }
        return FilePreview(path: path, name: (path as NSString).lastPathComponent, rules: matchedRules)
    }

    private static func conditionPreviews(_ rule: Rule, path: String, depth: Int, lastOpened: any LastOpenedMetadataProvider, lastMatched: Date?, now: Date, attributes: inout [String: JSONValue], tracker: ChangeTracker? = nil, allowOCR: Bool = true) throws -> [ConditionPreview] {
        guard rule.conditions.filter({ $0.kind == .peerRanking }).count <= 1 else { throw ActionError("Only one peer ranking condition is supported in a group") }
        var decided = false
        return try rule.conditions.map { condition in
            if needsOrderedConditions(rule) && decided {
                return ConditionPreview(kind: condition.kind, operator_: condition.operator, value: condition.displayValue, matched: false, detail: "Not evaluated")
            }
            let preview: ConditionPreview = try {
            if ChangeCondition.isChange(condition) {
                let value = try tracker?.evaluate(condition, path: path)
                return ConditionPreview(kind: condition.kind, operator_: condition.operator, value: "", matched: value ?? false, detail: value == nil ? "Persistent state is unavailable" : nil, known: value != nil)
            }
            if condition.kind == .peerRanking {
                let filters = rule.conditionMatch == .all ? rule.conditions.filter { $0.kind != .peerRanking } : []
                let value = try ConditionEvaluator.evaluatePeerRanking(condition, path: path, depth: depth, lastOpened: lastOpened, now: now, filters: filters, allowOCR: allowOCR)
                return ConditionPreview(kind: condition.kind, operator_: condition.operator, value: condition.displayValue, matched: value ?? false, detail: value == nil ? "Peer metadata was unavailable or the scan exceeded its limit." : nil, known: value != nil)
            }
            if condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) {
                let target: String
                switch group.target {
                case .current: target = "this item"
                case .parent: target = "the enclosing folder"
                case .anySibling: target = "any sibling"
                case .allSiblings: target = "all siblings"
                case .anyChild: target = "any contained item"
                case .allChildren: target = "all contained items"
                }
                let detail = group.conditions.map { $0.kind.label }.joined(separator: ", ")
                let result = try ConditionEvaluator.evaluateWithContext(condition, path: path, depth: depth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: &attributes, change: tracker.map { tracker in { condition, path, negated in try tracker.evaluate(condition, path: path, negated: negated != (rule.conditionMatch == .none)) } }, allowOCR: allowOCR)
                return ConditionPreview(kind: condition.kind, operator_: condition.operator,
                                        value: "\(group.match.rawValue.capitalized) conditions on \(target)",
                                        matched: result ?? false,
                                        detail: detail.isEmpty ? nil : detail, known: result != nil)
            }
            if condition.kind == .hazelScriptCondition {
                let matched = try ConditionEvaluator.evaluateWithContext(condition, path: path, depth: depth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, attributes: &attributes, allowOCR: allowOCR) ?? false
                return ConditionPreview(kind: condition.kind, operator_: condition.operator, value: "Script condition", matched: matched, detail: "Executed during Dry Run")
            }
            // `contents` runs the extraction pipeline once and reports which
            // strategy was used, so the Dry Run can show what was actually read.
            if condition.kind == .contents || condition.kind == .contentsWithoutOCR || condition.kind == .contentsWithOCR || condition.kind == .contentsWithPassword {
                let result = ConditionEvaluator.evaluateContents(condition, path: path, allowOCR: allowOCR)
                let available = rule.conditionMatch == .none || condition.kind == .contentsWithPassword ? try ConditionEvaluator.evaluateWithContext(condition, path: path, depth: depth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, requireAvailable: true, attributes: &attributes, allowOCR: allowOCR) : result.matched
                let detail: String
                if let message = result.message {
                    detail = "\(result.strategy.label) — \(message)"
                } else {
                    detail = result.strategy.label
                }
                return ConditionPreview(
                    kind: condition.kind,
                    operator_: condition.operator,
                    value: condition.displayValue,
                    matched: available ?? false,
                    detail: detail, known: available != nil
                )
            }
            let available = try ConditionEvaluator.evaluateWithContext(condition, path: path, depth: depth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, requireAvailable: rule.conditionMatch == .none, attributes: &attributes, allowOCR: allowOCR)
            return ConditionPreview(
                kind: condition.kind,
                operator_: condition.operator,
                value: condition.displayValue,
                matched: available ?? false, known: available != nil
            )
            }()
            if preview.known && (rule.conditionMatch == .all && !preview.matched || rule.conditionMatch != .all && preview.matched) { decided = true }
            return preview
        }
    }

    private static func conditionResultsMatch(_ results: [Bool?], _ match: ConditionMatch) -> Bool {
        if results.isEmpty { return true }
        switch match {
        case .all: return results.allSatisfy { $0 == true }
        case .any: return results.contains { $0 == true }
        case .none: return results.allSatisfy { $0 == false }
        }
    }

    /// Like `ruleInScope` + condition matching combined, but evaluates cheap
    /// conditions first and short-circuits, so an expensive `contents`
    /// extraction (PDF text, OCR, zip parsing, Spotlight) only runs when it
    /// can still change the outcome — e.g. a failing name check in an `.all`
    /// rule skips the OCR entirely. Reordering is safe because `.all` and
    /// `.any` are order-independent. Used by `run`, which only needs a
    /// yes/no answer; `previewFile` keeps the original order and evaluates
    /// every condition on purpose, to show each one's result in the Dry Run.
    private struct ConditionSignature: Encodable {
        let mode: ConditionMatch
        let conditions: [Condition]
    }

    public static func isTimeSensitive(_ rule: Rule) -> Bool {
        func sensitive(_ condition: Condition) -> Bool {
            if condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) {
                return group.conditions.contains(where: sensitive)
            }
            if condition.kind == .currentTime || condition.kind == .dateLastMatched || condition.kind == .dateComparison { return true }
            guard [.createdAt, .dateModified, .dateAdded, .dateLastOpened].contains(condition.kind) else { return false }
            return condition.operator.usesRelativeDateValue || [.beforeToday, .beforeThisWeek, .beforeThisMonth, .notThisWeek, .notThisMonth].contains(condition.operator)
        }
        return rule.conditions.contains(where: sensitive)
    }

    public static func isPeerSensitive(_ rule: Rule) -> Bool {
        func sensitive(_ condition: Condition) -> Bool {
            if condition.kind == .peerRanking { return true }
            guard condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) else { return false }
            return group.conditions.contains(where: sensitive)
        }
        return rule.conditions.contains(where: sensitive)
    }

    private static func hasScriptCondition(_ rule: Rule) -> Bool {
        func contains(_ condition: Condition) -> Bool {
            if condition.kind == .hazelScriptCondition { return true }
            guard condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) else { return false }
            return group.conditions.contains(where: contains)
        }
        return rule.conditions.contains(where: contains)
    }

    private static func conditionSignature(_ rule: Rule) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let encoded = try? encoder.encode(ConditionSignature(mode: rule.conditionMatch, conditions: rule.conditions)) else { return "" }
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    private static func needsOrderedConditions(_ rule: Rule) -> Bool {
        func dependsOnOrder(_ condition: Condition) -> Bool {
            if condition.kind == .hazelScriptCondition || condition.kind == .scriptAttribute || condition.kind == .customTableMatch || condition.kind == .customDateMatch || condition.kind == .customTextMatch || condition.kind == .dateComparison { return true }
            if condition.kind == .conditionGroup, let group = ConditionGroup.decode(condition.value) {
                return group.conditions.contains(where: dependsOnOrder)
            }
            return false
        }
        return rule.isHazelImported || rule.conditions.contains(where: dependsOnOrder)
    }

    private static func ruleMatches(_ rule: Rule, path: String, depth: Int, lastOpened: any LastOpenedMetadataProvider, lastMatched: Date? = nil, now: Date = Date(), attributes: inout [String: JSONValue], tracker: ChangeTracker? = nil, allowOCR: Bool = true) throws -> Bool {
        guard rule.conditions.filter({ $0.kind == .peerRanking }).count <= 1 else { throw ActionError("Only one peer ranking condition is supported in a group") }
        guard ruleInScope(rule, depth: depth) else { return false }
        if rule.conditions.isEmpty { return true }

        let ordered = needsOrderedConditions(rule)
            ? rule.conditions : rule.conditions.sorted { evaluationCost($0.kind) < evaluationCost($1.kind) }
        var unknown = false
        for condition in ordered {
            let result: Bool?
            if ChangeCondition.isChange(condition) { result = try tracker?.evaluate(condition, path: path, negated: rule.conditionMatch == .none) }
            else if condition.kind == .peerRanking {
                let filters = rule.conditionMatch == .all ? rule.conditions.filter { $0.kind != .peerRanking } : []
                result = try ConditionEvaluator.evaluatePeerRanking(condition, path: path, depth: depth, lastOpened: lastOpened, now: now, filters: filters, allowOCR: allowOCR)
            } else {
                result = try ConditionEvaluator.evaluateWithContext(condition, path: path, depth: depth, lastOpened: lastOpened, lastMatched: lastMatched, now: now, requireAvailable: rule.conditionMatch == .none, attributes: &attributes, change: tracker.map { tracker in { condition, path, negated in try tracker.evaluate(condition, path: path, negated: negated != (rule.conditionMatch == .none)) } }, allowOCR: allowOCR)
            }
            guard let result else { unknown = true; continue }
            if rule.conditionMatch == .all && !result { return false }
            if rule.conditionMatch == .any && result { return true }
            if rule.conditionMatch == .none && result { return false }
        }
        return !unknown && rule.conditionMatch != .any
    }

    /// Relative cost of evaluating a condition, used only to order evaluation so
    /// the cheap checks can short-circuit before the expensive ones. `contents`
    /// can read/parse the whole file (and run OCR), so it is always evaluated last.
    private static func evaluationCost(_ kind: ConditionKind) -> Int {
        (kind == .contents || kind == .contentsWithoutOCR || kind == .contentsWithOCR || kind == .contentsWithPassword) ? 1 : 0
    }

    private static func ruleInScope(_ rule: Rule, depth: Int) -> Bool {
        if rule.isHazelImported { return true }
        guard let limit = rule.recursionDepth else { return true }
        if limit >= 0 { return depth <= Int(limit) }
        return depth == 0
    }

    public static func pathDepth(root: String, path: String) -> Int? {
        let rootComponents = (root as NSString).pathComponents
        let pathComponents = (path as NSString).pathComponents
        guard pathComponents.count >= rootComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return max(0, pathComponents.count - rootComponents.count - 1)
    }

    public static func walkEntries(root: String, maxDepth: Int?) -> [ScopedPath] {
        var entries: [ScopedPath] = []
        forEachEntry(root: root, maxDepth: maxDepth) { entry in
            entries.append(entry)
        }
        return entries
    }

    public static func forEachEntry(root: String, maxDepth: Int?, _ visit: (ScopedPath) -> Void) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        walkEntriesInner(root: root, maxDepth: maxDepth, depth: 0, visit: visit)
    }

    private static func walkEntriesInner(root: String, maxDepth: Int?, depth: Int, visit: (ScopedPath) -> Void) {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for child in children.sorted() {
            if SystemFileFilter.isExcluded(child) { continue }
            let childPath = (root as NSString).appendingPathComponent(child)
            visit(ScopedPath(path: childPath, depth: depth))

            var isDir: ObjCBool = false
            var isSymlink = false
            if let attrs = try? FileManager.default.attributesOfItem(atPath: childPath) {
                isSymlink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
            }
            guard FileManager.default.fileExists(atPath: childPath, isDirectory: &isDir), isDir.boolValue, !isSymlink else {
                continue
            }
            if let limit = maxDepth, depth >= limit { continue }
            walkEntriesInner(root: childPath, maxDepth: maxDepth, depth: depth + 1, visit: visit)
        }
    }

    public static func maxRuleDepth(_ rules: [Rule]) -> Int? {
        let enabledRules = rules.filter { $0.enabled && !$0.isHazelImported }
        guard !enabledRules.isEmpty else { return 0 }
        if enabledRules.contains(where: { $0.recursionDepth == nil }) { return nil }
        return enabledRules.compactMap { rule in
            rule.recursionDepth.map { max(0, Int($0)) }
        }.max()
    }

    /// Rules for an individual watcher event: imported rules can reach a
    /// descendant only if every intervening folder permits Hazel recursion.
    public static func rulesForPath(root: String, path: String, rules: [Rule], isPro: Bool = true, lastOpened: any LastOpenedMetadataProvider = SpotlightLastOpenedMetadata(), recurseDecision: ((String) -> Bool?)? = nil) -> [Rule] {
        guard let depth = pathDepth(root: root, path: path), depth > 0 else { return rules }
        let rootParts = (root as NSString).standardizingPath as NSString
        let pathParts = ((path as NSString).standardizingPath as NSString).pathComponents
        let rootCount = rootParts.pathComponents.count
        var ancestor = rootParts as String
        for component in pathParts[rootCount..<(pathParts.count - 1)] {
            ancestor = (ancestor as NSString).appendingPathComponent(component)
            guard isRealDirectory(ancestor), recurseDecision?(ancestor) ?? hazelCanDescend(path: ancestor, depth: pathDepth(root: root, path: ancestor) ?? 0, rules: rules, lastOpened: lastOpened, isPro: isPro) else {
                return rules.filter { !$0.isHazelImported }
            }
        }
        return rules
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeDirectory else { return false }
        return true
    }

    private static func hazelCanDescend(path: String, depth: Int, rules: [Rule], lastOpened: any LastOpenedMetadataProvider, isPro: Bool) -> Bool {
        for rule in rules where rule.enabled && rule.isHazelImported && (isPro || FreePlan.requiredFeature(for: rule) == nil) {
            if rule.importError != nil { return false }
            var attributes: [String: JSONValue] = [:]
            guard (try? ruleMatches(rule, path: path, depth: depth, lastOpened: lastOpened, attributes: &attributes, allowOCR: isPro)) == true else { continue }
            let result = previewActions(rule, path: path)
            if result.actions.contains(where: { $0.kind == .hazelRecurse && $0.status == .wouldRun }) { return true }
            if result.isTerminal || !result.continues { return false }
        }
        return false
    }

    /// Stream entries in directory order so actions on a folder happen before
    /// scanning it. Native scope and Hazel's per-folder decisions coexist.
    public static func forEachRuleEntry(root: String, rules: [Rule], subtree: String? = nil, isPro: Bool = true, lastOpened: any LastOpenedMetadataProvider = SpotlightLastOpenedMetadata(), _ visit: @escaping (ScopedPath, [Rule]) -> Void) {
        forEachRuleEntryInner(root: root, rules: rules, subtree: subtree, isPro: isPro, lastOpened: lastOpened, ancestorDecision: nil) { entry, active, _ in
            visit(entry, active)
            return nil
        }
    }

    public static func forEachRuleEntryExecuting(root: String, rules: [Rule], subtree: String? = nil, isPro: Bool = true, lastOpened: any LastOpenedMetadataProvider = SpotlightLastOpenedMetadata(), ancestorDecision: ((String) -> Bool?)? = nil, _ visit: @escaping (ScopedPath, [Rule], @escaping (String) -> Void) -> Bool) {
        forEachRuleEntryInner(root: root, rules: rules, subtree: subtree, isPro: isPro, lastOpened: lastOpened, ancestorDecision: ancestorDecision) { entry, active, recurse in visit(entry, active, recurse) }
    }

    private static func forEachRuleEntryInner(root: String, rules: [Rule], subtree: String?, isPro: Bool, lastOpened: any LastOpenedMetadataProvider, ancestorDecision: ((String) -> Bool?)?, _ visit: @escaping (ScopedPath, [Rule], @escaping (String) -> Void) -> Bool?) {
        let nativeDepth = maxRuleDepth(rules)
        func contains(_ root: String, _ path: String) -> Bool {
            let a = (root as NSString).pathComponents
            let b = (path as NSString).pathComponents
            return b.count >= a.count && Array(b.prefix(a.count)) == a
        }
        func walk(_ directory: String, _ depth: Int, _ hazelAllowed: Bool) {
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
            for child in children.sorted() where !SystemFileFilter.isExcluded(child) {
                let path = (directory as NSString).appendingPathComponent(child)
                if let subtree, !contains(subtree, path) && !contains(path, subtree) { continue }
                let activeRules = hazelAllowed ? rules : rules.filter { !$0.isHazelImported }
                var descendHazel = false
                var traversed = false
                if subtree == nil || contains(subtree!, path) {
                    let recurse: (String) -> Void = { target in
                        guard !traversed, isRealDirectory(target) else { return }
                        traversed = true
                        walk(target, depth + 1, true)
                    }
                    if let actual = visit(ScopedPath(path: path, depth: depth), activeRules, recurse) {
                        descendHazel = hazelAllowed && actual && !traversed
                    } else {
                        descendHazel = hazelAllowed && isRealDirectory(path) && hazelCanDescend(path: path, depth: depth, rules: rules, lastOpened: lastOpened, isPro: isPro)
                    }
                } else {
                    descendHazel = hazelAllowed && isRealDirectory(path) && (ancestorDecision?(path) ?? hazelCanDescend(path: path, depth: depth, rules: rules, lastOpened: lastOpened, isPro: isPro))
                }
                guard isRealDirectory(path) else { continue }
                let descendNative = nativeDepth == nil || depth < nativeDepth!
                if !traversed && (descendHazel || descendNative) { walk(path, depth + 1, descendHazel) }
            }
        }
        guard isRealDirectory(root) else { return }
        walk(root, 0, true)
    }

    /// Runs one rule's actions against `path` in order, deciding each one
    /// the exact same way `previewActions` would (via `ActionExecutor.plan`)
    /// before acting on it — the single place preview and execution can
    /// never disagree.
    private static func runActions(_ rule: Rule, path: String, batchId: String, platform: any ActionPlatform, watchedRoot: String?, counterStore: (any FolderCounterStore)?, uploadServers: [UploadServer], initialAttributes: [String: JSONValue], beforeAction: (() throws -> Void)?, onRecurse: ((String) -> Void)?) -> (history: [HistoryEntry], copiedPaths: [String], finalPath: String, isTerminal: Bool, continues: Bool, recurses: Bool) {
        let sorted = rule.actions.sorted { $0.position < $1.position }

        var history: [HistoryEntry] = []
        var copiedPaths: [String] = []
        var current = path
        var stoppedOnTerminal = false
        var terminalAfterRule = false
        let haltOnFailure = rule.isHazelImported || sorted.contains { $0.kind == .runHazelAppleScript || $0.kind == .runHazelShellScript || $0.kind == .runHazelOSA || $0.kind == .runWorkflow || $0.kind == .upload || $0.kind == .syncToFolder }
        var continues = false
        var recurses = false
        var hazelContext = sorted.contains { $0.params["hazel_pattern_tokens"] != nil || $0.kind == .runHazelOSA } ? HazelPatternContext(path: path, actions: sorted) : nil
        hazelContext?.attributes = initialAttributes
        hazelContext?.ruleName = rule.name

        actionsLoop: for action in sorted {
            if stoppedOnTerminal { break }
            if !rule.isHazelImported && (action.kind == .hazelRecurse || action.kind == .hazelContinue) {
                history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name, actionKind: action.kind, originalPath: current, resultPath: current, undo: Undo.none.toJSON(), reversible: false, status: .failed, message: "Enable Hazel rule ordering to use this action."))
                stoppedOnTerminal = true
                break
            }
            if action.kind == .hazelContinue { continues = true; continue }
            if action.kind == .hazelRecurse {
                guard isRealDirectory(current) else {
                    history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name, actionKind: action.kind, originalPath: current, resultPath: current, undo: Undo.none.toJSON(), reversible: false, status: .failed, message: "Cannot run rules on contents of an item that is not a folder."))
                    stoppedOnTerminal = true
                    break
                }
                guard let onRecurse else {
                    history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name, actionKind: action.kind, originalPath: current, resultPath: current, undo: Undo.none.toJSON(), reversible: false, status: .failed, message: "Running rules on folder contents requires a folder scan.") )
                    stoppedOnTerminal = true
                    break
                }
                recurses = true
                onRecurse(current)
                continue
            }
            let original = current
            var reservation: FolderCounterReservation?
            var counterCommitted = false
            defer {
                if let reservation, !counterCommitted {
                    do { try counterStore?.rollback(reservation) }
                    catch {
                        history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name, actionKind: action.kind, originalPath: original, resultPath: original, undo: Undo.none.toJSON(), reversible: false, status: .failed, message: "Could not roll back folder counter: \(error)"))
                        stoppedOnTerminal = true
                    }
                }
            }
            do {
                if actionUsesCounter(action) {
                    guard let counterStore else { throw ActionError("A folder counter store is required for this action") }
                    let reserved: FolderCounterReservation
                    if counterUsesLowest(action) {
                        guard action.kind == .rename else { throw ActionError("Lowest-available counters require a Rename action") }
                        reserved = try counterStore.reserveLowest(folderId: rule.folderId) { value in
                            var candidateContext = hazelContext
                            candidateContext?.counterValue = value
                            guard let target = try ActionExecutor.plan(action, path: current, contextPath: path, hazelContext: candidateContext, watchedRoot: watchedRoot, uploadServers: uploadServers).targetPath else {
                                throw ActionError("Cannot determine the counter destination")
                            }
                            return URL(fileURLWithPath: target).standardizedFileURL.path
                        }
                    } else { reserved = try counterStore.reserve(folderId: rule.folderId) }
                    reservation = reserved
                    hazelContext?.counterValue = reserved.value
                }
                let actionPlan = try ActionExecutor.plan(action, path: current, contextPath: path, hazelContext: hazelContext, watchedRoot: watchedRoot, uploadServers: uploadServers)

                switch actionPlan.status {
                case .wouldSkip:
                    // `description` already explains *why* for the
                    // conflict-aware skips (already in destination, or
                    // explicitly configured to skip); everything else is
                    // skipped because it simply wouldn't change the file.
                    let isConflictAwareSkip = actionPlan.description == "Already in destination" || actionPlan.description.hasPrefix("Skip —")
                    history.append(
                        HistoryEntry(
                            batchId: batchId,
                            ruleId: rule.id,
                            ruleName: rule.name,
                            actionKind: action.kind,
                            originalPath: original,
                            resultPath: original,
                            undo: Undo.none.toJSON(),
                            reversible: false,
                            status: .skipped,
                            message: isConflictAwareSkip ? actionPlan.description : "Skipped because the action would not change this file."
                        )
                    )
                case .blockedByConflict:
                    history.append(
                        HistoryEntry(
                            batchId: batchId,
                            ruleId: rule.id,
                            ruleName: rule.name,
                            actionKind: action.kind,
                            originalPath: original,
                            resultPath: original,
                            undo: Undo.none.toJSON(),
                            reversible: false,
                            status: .failed,
                            message: "A file already exists at the destination."
                        )
                    )
                    if haltOnFailure || terminalFileAction(action.kind) { stoppedOnTerminal = true; break actionsLoop }
                case .blocked:
                    history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name,
                                                actionKind: action.kind, originalPath: original, resultPath: original,
                                                undo: Undo.none.toJSON(), reversible: false, status: .failed,
                                                message: actionPlan.description))
                    if haltOnFailure || terminalFileAction(action.kind) { stoppedOnTerminal = true; break actionsLoop }
                case .needsConfirmation:
                    history.append(
                        HistoryEntry(
                            batchId: batchId,
                            ruleId: rule.id,
                            ruleName: rule.name,
                            actionKind: action.kind,
                            originalPath: original,
                            resultPath: original,
                            undo: Undo.none.toJSON(),
                            reversible: false,
                            status: .needsConfirmation
                        )
                    )
                    if haltOnFailure || terminalFileAction(action.kind) { stoppedOnTerminal = true; break actionsLoop }
                case .wouldRun:
                    try beforeAction?()
                    let applied = try ActionExecutor.execute(action, path: current, contextPath: path, hazelContext: hazelContext, platform: platform, watchedRoot: watchedRoot, uploadServers: uploadServers)
                    if let reservation {
                        try counterStore?.commit(reservation)
                        counterCommitted = true
                    }
                    hazelContext?.attributes.merge(applied.outputAttributes) { _, new in new }
                    let resultPath: String
                    if let copiedPath = applied.copiedPath {
                        resultPath = copiedPath
                        if !rule.isHazelImported { copiedPaths.append(copiedPath) }
                    } else {
                        resultPath = applied.newPath
                    }
                    let resultIdentity = FileFingerprint.identity(resultPath)
                    history.append(
                        HistoryEntry(
                            batchId: batchId,
                            ruleId: rule.id,
                            ruleName: rule.name,
                            actionKind: action.kind,
                            originalPath: original,
                            resultPath: resultPath,
                            undo: applied.undo.toJSON(),
                            reversible: applied.undo.isReversible,
                            resultVolumeId: resultIdentity?.volumeId,
                            resultFileId: resultIdentity?.fileId
                        )
                    )
                    current = rule.isHazelImported ? (applied.copiedPath ?? applied.newPath) : applied.newPath
                    if rule.isHazelImported && action.kind == .moveToTrash { terminalAfterRule = true }
                    if applied.stopsActionChain { stoppedOnTerminal = true; break actionsLoop }
                }

                let continuesAfterTrash = rule.isHazelImported && action.kind == .moveToTrash && actionPlan.status == .wouldRun
                if (!continuesAfterTrash && shouldStopActionChain(after: action, plan: actionPlan)) || (rule.isHazelImported && action.kind == .copyToFolder && actionPlan.status == .wouldSkip) {
                    stoppedOnTerminal = true
                    break
                }
            } catch {
                if error as? FreePlanError == .monthlyFileLimit {
                    history.append(HistoryEntry(batchId: batchId, ruleId: rule.id, ruleName: rule.name, actionKind: action.kind, originalPath: original, resultPath: original, undo: Undo.none.toJSON(), reversible: false, status: .failed, message: FreePlanError.monthlyFileLimit.localizedDescription))
                    stoppedOnTerminal = true
                    break
                }
                history.append(
                    HistoryEntry(
                        batchId: batchId,
                        ruleId: rule.id,
                        ruleName: rule.name,
                        actionKind: action.kind,
                        originalPath: original,
                        resultPath: original,
                        undo: Undo.none.toJSON(),
                        reversible: false,
                        status: .failed,
                        message: String(describing: error)
                    )
                )
                if action.kind == .setFinderLabel || terminalFileAction(action.kind) || haltOnFailure ||
                    (action.kind == .moveToFolder && action.params[ActionParam.discardDuplicates]?.boolValue == true) {
                    stoppedOnTerminal = true
                    break
                }
            }
        }
        return (history, copiedPaths, current, stoppedOnTerminal || terminalAfterRule, continues, recurses)
    }

    private static func actionUsesCounter(_ action: Action) -> Bool {
        (action.params[HazelPattern.tokensKey]?.arrayValue ?? []).contains { $0["type"]?.stringValue == "counter" }
    }

    private static func counterUsesLowest(_ action: Action) -> Bool {
        (action.params[HazelPattern.tokensKey]?.arrayValue ?? []).contains { $0["type"]?.stringValue == "counter" && $0["allocation"]?.stringValue == "lowest" }
    }

    private static func previewActions(_ rule: Rule, path: String, watchedRoot: String? = nil, counterStore: (any FolderCounterStore)? = nil, uploadServers: [UploadServer] = [], initialAttributes: [String: JSONValue] = [:], onRecurse: ((String) -> Void)? = nil) -> (actions: [ActionPreview], copiedPaths: [String], finalPath: String, isTerminal: Bool, continues: Bool) {
        let sorted = rule.actions.sorted { $0.position < $1.position }

        var actions: [ActionPreview] = []
        var copiedPaths: [String] = []
        var current = path
        var stoppedOnTerminal = false
        var terminalAfterRule = false
        let haltOnFailure = rule.isHazelImported || sorted.contains { $0.kind == .runHazelAppleScript || $0.kind == .runHazelShellScript || $0.kind == .runHazelOSA || $0.kind == .runWorkflow || $0.kind == .upload || $0.kind == .syncToFolder }
        var continues = false
        var hazelContext = sorted.contains { $0.params["hazel_pattern_tokens"] != nil || $0.kind == .runHazelOSA } ? HazelPatternContext(path: path, actions: sorted) : nil
        hazelContext?.attributes = initialAttributes
        hazelContext?.ruleName = rule.name

        for action in sorted {
            if action.kind == .hazelContinue || action.kind == .hazelRecurse {
                if !rule.isHazelImported {
                    actions.append(ActionPreview(kind: action.kind, description: "Enable Hazel rule ordering to use this action.", sourcePath: current, targetPath: nil, status: .blocked))
                    stoppedOnTerminal = true
                    break
                }
                if action.kind == .hazelContinue { continues = true }
                if action.kind == .hazelRecurse && !isRealDirectory(current) && !isRealDirectory(path) {
                    actions.append(ActionPreview(kind: action.kind, description: "Cannot run rules on contents of an item that is not a folder.", sourcePath: current, targetPath: nil, status: .blocked))
                    stoppedOnTerminal = true
                    break
                }
                if action.kind == .hazelRecurse { onRecurse?(FileManager.default.fileExists(atPath: current) ? current : path) }
                actions.append(ActionPreview(kind: action.kind, description: action.kind == .hazelContinue ? "Continue matching rules" : "Run rules on folder contents", sourcePath: current, targetPath: nil, status: .wouldRun))
                continue
            }
            var previewReservation: FolderCounterReservation?
            var previewCommitted = false
            defer {
                if let previewReservation, !previewCommitted, let previewStore = counterStore as? PreviewFolderCounterStore {
                    try? previewStore.rollback(previewReservation)
                }
            }
            do {
                if actionUsesCounter(action) {
                    guard let counterStore else { throw ActionError("A folder counter store is required for this action") }
                    if counterUsesLowest(action) {
                        guard action.kind == .rename else { throw ActionError("Lowest-available counters require a Rename action") }
                        let previewStore = (counterStore as? PreviewFolderCounterStore) ?? PreviewFolderCounterStore(underlying: counterStore)
                        let reservation = try previewStore.reserveLowest(folderId: rule.folderId) { value in
                            var candidateContext = hazelContext
                            candidateContext?.counterValue = value
                            guard let target = try ActionExecutor.plan(action, path: current, contextPath: path, hazelContext: candidateContext, watchedRoot: watchedRoot, uploadServers: uploadServers).targetPath else {
                                throw ActionError("Cannot determine the counter destination")
                            }
                            return URL(fileURLWithPath: target).standardizedFileURL.path
                        }
                        if counterStore is PreviewFolderCounterStore { previewReservation = reservation }
                        hazelContext?.counterValue = reservation.value
                    } else if let previewStore = counterStore as? PreviewFolderCounterStore {
                        let reservation = try previewStore.reserve(folderId: rule.folderId)
                        previewReservation = reservation
                        hazelContext?.counterValue = reservation.value
                    } else {
                        hazelContext?.counterValue = try counterStore.nextValue(folderId: rule.folderId)
                    }
                }
                let plan = try ActionExecutor.plan(action, path: current, contextPath: path, hazelContext: hazelContext, watchedRoot: watchedRoot, uploadServers: uploadServers)
                actions.append(
                    ActionPreview(
                        kind: plan.kind,
                        description: plan.description,
                        sourcePath: plan.sourcePath,
                        targetPath: plan.targetPath,
                        status: plan.status,
                        warning: plan.warning
                    )
                )

                if (haltOnFailure || terminalFileAction(action.kind)) && [.blocked, .blockedByConflict, .needsConfirmation].contains(plan.status) {
                    stoppedOnTerminal = true
                    break
                }

                if plan.status == .wouldRun {
                    previewCommitted = true
                    if let copiedPath = plan.copiedPath {
                        if !rule.isHazelImported { copiedPaths.append(copiedPath) }
                    }
                    current = rule.isHazelImported ? (plan.copiedPath ?? plan.finalPath) : plan.finalPath
                    if rule.isHazelImported && action.kind == .moveToTrash { terminalAfterRule = true }
                }

                let continuesAfterTrash = rule.isHazelImported && action.kind == .moveToTrash && plan.status == .wouldRun
                if (!continuesAfterTrash && shouldStopActionChain(after: action, plan: plan)) || (rule.isHazelImported && action.kind == .copyToFolder && plan.status == .wouldSkip) {
                    stoppedOnTerminal = true
                    break
                }
            } catch {
                actions.append(
                    ActionPreview(
                        kind: action.kind,
                        description: "Preview unavailable: \(error)",
                        sourcePath: current,
                        targetPath: nil,
                        status: (action.kind == .setFinderLabel || terminalFileAction(action.kind) || haltOnFailure) ? .blocked : .wouldSkip
                    )
                )
                if action.kind == .setFinderLabel || terminalFileAction(action.kind) || haltOnFailure {
                    stoppedOnTerminal = true
                    break
                }
            }
        }

        return (actions, copiedPaths, current, stoppedOnTerminal || terminalAfterRule, continues)
    }

    private static func shouldStopActionChain(after action: Action, plan: ActionPlan) -> Bool {
        if plan.stopsActionChain { return true }
        guard plan.isTerminal else { return false }
        return action.kind != .moveToFolder || plan.status != .wouldRun
    }

    private static func terminalFileAction(_ kind: ActionKind) -> Bool {
        kind == .moveToTrash || kind == .delete || kind == .moveToFolder
    }
}
