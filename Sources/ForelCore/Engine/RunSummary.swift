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
        guard !parts.isEmpty else { return L10n.string("run_summary_run_complete_matching_files") }
        return L10n.string("run_summary_run_complete", parts.joined(separator: ", "))
    }

    private static func firstPart(_ status: HistoryStatus, _ count: Int) -> String {
        switch status {
        case .applied: L10n.plural("run_summary_actions_applied", count)
        case .failed: L10n.plural("run_summary_actions_failed", count)
        case .skipped: L10n.plural("run_summary_actions_skipped", count)
        default: L10n.plural("run_summary_actions_awaiting_confirmation", count)
        }
    }

    /// Follows the first part, as in “2 actions applied, 1 failed”.
    private static func laterPart(_ status: HistoryStatus, _ count: Int) -> String {
        switch status {
        case .applied: L10n.plural("run_summary_applied", count)
        case .failed: L10n.plural("run_summary_failed", count)
        case .skipped: L10n.plural("run_summary_skipped", count)
        default: L10n.plural("run_summary_awaiting_confirmation", count)
        }
    }
}
