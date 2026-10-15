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
        let outcomes: [(HistoryStatus, String)] = [
            (.applied, "applied"),
            (.failed, "failed"),
            (.skipped, "skipped"),
            (.needsConfirmation, "awaiting confirmation"),
        ]
        var parts: [String] = []
        for (status, label) in outcomes {
            let count = history.filter { $0.status == status }.count
            guard count > 0 else { continue }
            // Only the first part names what is being counted:
            // "2 actions applied, 1 failed".
            parts.append(parts.isEmpty ? "\(count) action\(count == 1 ? "" : "s") \(label)" : "\(count) \(label)")
        }
        guard !parts.isEmpty else { return "Run complete — no matching files" }
        return "Run complete — " + parts.joined(separator: ", ")
    }
}
