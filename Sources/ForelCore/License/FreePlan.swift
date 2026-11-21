import Foundation

public enum ProFeature: String, CaseIterable, Identifiable, Sendable {
    case ocr, libraryImports
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ocr: L10n.string("free_plan_text_recognition_ocr")
        case .libraryImports: L10n.string("free_plan_media_library_imports")
        }
    }
    public var benefit: String {
        switch self {
        case .ocr: L10n.string("free_plan_organize_scanned_pdfs_images")
        case .libraryImports: L10n.string("free_plan_import_matching_files_directly")
        }
    }
}

/// Applies the same Free allowance to previews, manual runs, and watching.
/// Folder allowances use the persisted order, including disabled entries.
public enum FreePlan {
    public static let folderLimit = 2
    public static let monthlyFileLimit = 300

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
        case .folderLimit: L10n.string("free_plan_two_folders_limit")
        case .proFolder: L10n.string("free_plan_folder_outside_free_allowance")
        case .monthlyFileLimit: L10n.string("free_plan_forel_free_reached_limit")
        case .feature(let feature): L10n.string("free_plan_requires_forel_pro_rule", feature.title)
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
            .filter { $0.enabled && $0.isSupported && (isPro || FreePlan.requiredFeature(for: $0) == nil) }
    }
}
