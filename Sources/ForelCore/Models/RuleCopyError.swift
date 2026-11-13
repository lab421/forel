import Foundation

public enum RuleCopyError: Error, LocalizedError {
    case noSelection, sameFolder, missingFolder, missingRules

    public var errorDescription: String? {
        switch self {
        case .noSelection: L10n.string("copy_rules_select_least_one_rule")
        case .sameFolder: L10n.string("copy_rules_choose_different_watched_folder")
        case .missingFolder: L10n.string("copy_rules_folder_been_removed_choose")
        case .missingRules: L10n.string("copy_rules_some_selected_rules_longer")
        }
    }
}
