import Foundation

public enum RuleCopyError: Error, LocalizedError {
    case noSelection, sameFolder, missingFolder, missingRules

    public var errorDescription: String? {
        switch self {
        case .noSelection: "Select at least one rule to copy."
        case .sameFolder: "Choose a different watched folder for the copies."
        case .missingFolder: "A folder has been removed. Choose another watched folder."
        case .missingRules: "Some selected rules no longer exist. Select the rules again."
        }
    }
}
