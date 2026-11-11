import Foundation

public enum RuleCopyError: Error, LocalizedError {
    case noSelection, sameFolder, missingFolder, missingRules

    public var errorDescription: String? {
        switch self {
        case .noSelection: String(localized: "Select at least one rule to copy.", bundle: .forelStrings, comment: "Error when copying rules to another folder")
        case .sameFolder: String(localized: "Choose a different watched folder for the copies.", bundle: .forelStrings, comment: "Error when copying rules to another folder")
        case .missingFolder: String(localized: "A folder has been removed. Choose another watched folder.", bundle: .forelStrings, comment: "Error when copying rules to another folder")
        case .missingRules: String(localized: "Some selected rules no longer exist. Select the rules again.", bundle: .forelStrings, comment: "Error when copying rules to another folder")
        }
    }
}
