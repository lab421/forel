import Foundation

public enum ProFeature: String, CaseIterable, Identifiable, Sendable {
    case ocr, libraryImports
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ocr: "Text recognition (OCR)"
        case .libraryImports: "Media library imports"
        }
    }
    public var benefit: String {
        switch self {
        case .ocr: "Organize scanned PDFs and images by the text they contain. Recognition runs locally on your Mac."
        case .libraryImports: "Import matching files directly into Photos, Music, and TV."
        }
    }
}

/// Applies the same Free allowance to previews, manual runs, and watching.
/// Folder allowances use the persisted order, including disabled entries.
public enum FreePlan {
    public static let folderLimit = 2
    public static let monthlyFileLimit = 500

    public static func requiredFeature(for action: ActionKind) -> ProFeature? {
        switch action {
        case .importToLibrary: .libraryImports
        default: nil
        }
    }

    public static func requiredFeature(for rule: Rule) -> ProFeature? {
        return rule.actions.compactMap { requiredFeature(for: $0.kind) }.first
    }

    public static func validate(_ rule: Rule, isPro: Bool) throws {
        if !isPro, rule.enabled, let feature = requiredFeature(for: rule) {
            throw FreePlanError.feature(feature)
        }
    }

    public static func canAddFolder(count: Int, isPro: Bool) -> Bool {
        isPro || count < folderLimit
    }

    public static func allows(folderID: String, folders: [WatchedFolder], isPro: Bool) -> Bool {
        isPro || folders.prefix(folderLimit).contains { $0.id == folderID }
    }

}

public enum FreePlanError: Error, LocalizedError, Equatable {
    case folderLimit, proFolder, monthlyFileLimit
    case feature(ProFeature)
    public var errorDescription: String? {
        switch self {
        case .folderLimit: "Forel Free supports 2 watched folders. Remove a folder or activate Pro to add another."
        case .proFolder: "This folder is outside the Free allowance. Reorder folders or activate Pro to add rules."
        case .monthlyFileLimit: "Forel Free has processed 500 files this month. Processing resumes next month, or activate Pro for unlimited files. Your remaining files stay in place."
        case .feature(let feature): "\(feature.title) requires Forel Pro. This rule is kept but cannot run in Free."
        }
    }
}

extension Database {
    public func insertFolder(_ folder: WatchedFolder, isPro: Bool) throws {
        guard FreePlan.canAddFolder(count: try listFolders().count, isPro: isPro) else { throw FreePlanError.folderLimit }
        try insertFolder(folder)
    }

    public func insertRule(_ rule: Rule, isPro: Bool) throws {
        try FreePlan.validate(rule, isPro: isPro)
        guard FreePlan.allows(folderID: rule.folderId, folders: try listFolders(), isPro: isPro) else { throw FreePlanError.proFolder }
        try insertRule(rule)
    }

    public func updateRule(_ rule: Rule, isPro: Bool) throws {
        try FreePlan.validate(rule, isPro: isPro)
        try updateRule(rule)
    }

    public func executionRules(folderID: String, isPro: Bool) throws -> [Rule] {
        guard FreePlan.allows(folderID: folderID, folders: try listFolders(), isPro: isPro) else { return [] }
        return try listRules(folderId: folderID)
            .filter { $0.enabled && (isPro || FreePlan.requiredFeature(for: $0) == nil) }
    }
}
