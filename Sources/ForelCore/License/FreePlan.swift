import Foundation

/// Applies the same Free allowance to previews, manual runs, and watching.
/// Arrays use the persisted folder/rule order, including disabled entries.
public enum FreePlan {
    public static let folderLimit = 2
    public static let ruleLimit = 5

    public static func canAddFolder(count: Int, isPro: Bool) -> Bool {
        isPro || count < folderLimit
    }

    public static func canAddRule(count: Int, isPro: Bool) -> Bool {
        isPro || count < ruleLimit
    }

    public static func allows(folderID: String, folders: [WatchedFolder], isPro: Bool) -> Bool {
        isPro || folders.prefix(folderLimit).contains { $0.id == folderID }
    }

    public static func rules(_ rules: [Rule], isPro: Bool) -> [Rule] {
        isPro ? rules : Array(rules.prefix(ruleLimit))
    }
}

public enum FreePlanError: Error, LocalizedError {
    case folderLimit, ruleLimit, proFolder
    public var errorDescription: String? {
        switch self {
        case .folderLimit: "Forel Free supports 2 watched folders. Remove a folder or activate Pro to add another."
        case .ruleLimit: "Forel Free supports 5 rules per folder, including disabled rules. Delete a rule or activate Pro to add another."
        case .proFolder: "This folder is outside the Free allowance. Reorder folders or activate Pro to add rules."
        }
    }
}

extension Database {
    public func insertFolder(_ folder: WatchedFolder, isPro: Bool) throws {
        guard FreePlan.canAddFolder(count: try listFolders().count, isPro: isPro) else { throw FreePlanError.folderLimit }
        try insertFolder(folder)
    }

    public func insertRule(_ rule: Rule, isPro: Bool) throws {
        guard FreePlan.allows(folderID: rule.folderId, folders: try listFolders(), isPro: isPro) else { throw FreePlanError.proFolder }
        guard FreePlan.canAddRule(count: try listRules(folderId: rule.folderId).count, isPro: isPro) else { throw FreePlanError.ruleLimit }
        try insertRule(rule)
    }

    public func executionRules(folderID: String, isPro: Bool) throws -> [Rule] {
        guard FreePlan.allows(folderID: folderID, folders: try listFolders(), isPro: isPro) else { return [] }
        return FreePlan.rules(try listRules(folderId: folderID), isPro: isPro).filter(\.enabled)
    }
}
