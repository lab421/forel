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

/// The one-line result shown after a manual Run Now. Counts each outcome
/// separately: a run whose actions all failed must not read as a success.
public enum RunSummary {
    public static func message(for history: [HistoryEntry]) -> String {
        let statuses: [HistoryStatus] = [.applied, .failed, .skipped, .needsConfirmation]
        var parts: [String] = []
        for status in statuses {
            let count = history.filter { $0.status == status }.count
            guard count > 0 else { continue }
            // Only the first part names what is being counted:
            // "2 actions applied, 1 failed".
            parts.append(parts.isEmpty ? firstPart(status, count) : laterPart(status, count))
        }
        guard !parts.isEmpty else { return String(localized: "Run complete — no matching files", bundle: .forelStrings, comment: "Result of Run Now") }
        return String(localized: "Run complete — \(parts.joined(separator: ", "))", bundle: .forelStrings, comment: "Result of Run Now; %@ lists the counts, as in “2 actions applied, 1 failed”")
    }

    private static func firstPart(_ status: HistoryStatus, _ count: Int) -> String {
        switch status {
        case .applied: String(localized: "\(count) actions applied", bundle: .forelStrings, comment: "Result of Run Now")
        case .failed: String(localized: "\(count) actions failed", bundle: .forelStrings, comment: "Result of Run Now")
        case .skipped: String(localized: "\(count) actions skipped", bundle: .forelStrings, comment: "Result of Run Now")
        default: String(localized: "\(count) actions awaiting confirmation", bundle: .forelStrings, comment: "Result of Run Now")
        }
    }

    /// Follows the first part, as in “2 actions applied, 1 failed”.
    private static func laterPart(_ status: HistoryStatus, _ count: Int) -> String {
        switch status {
        case .applied: String(localized: "\(count) applied", bundle: .forelStrings, comment: "Result of Run Now, after “2 actions failed, ”")
        case .failed: String(localized: "\(count) failed", bundle: .forelStrings, comment: "Result of Run Now, after “2 actions applied, ”")
        case .skipped: String(localized: "\(count) skipped", bundle: .forelStrings, comment: "Result of Run Now, after “2 actions applied, ”")
        default: String(localized: "\(count) awaiting confirmation", bundle: .forelStrings, comment: "Result of Run Now, after “2 actions applied, ”")
        }
    }
}
