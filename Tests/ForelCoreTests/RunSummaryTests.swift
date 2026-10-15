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
import Testing
@testable import ForelCore

@Suite struct RunSummaryTests {
    private func entry(_ status: HistoryStatus) -> HistoryEntry {
        HistoryEntry(
            batchId: "batch",
            ruleId: "rule",
            ruleName: "rule",
            actionKind: .moveToFolder,
            originalPath: "/tmp/a.pdf",
            resultPath: "/tmp/a.pdf",
            undo: Undo.none.toJSON(),
            reversible: false,
            status: status
        )
    }

    @Test func noHistoryMeansNoMatchingFiles() {
        #expect(RunSummary.message(for: []) == "Run complete — no matching files")
    }

    @Test func appliedActionsAreCounted() {
        #expect(RunSummary.message(for: [entry(.applied)]) == "Run complete — 1 action applied")
        #expect(RunSummary.message(for: [entry(.applied), entry(.applied)]) == "Run complete — 2 actions applied")
    }

    @Test func failedActionsAreNeverReportedAsApplied() {
        #expect(RunSummary.message(for: [entry(.failed)]) == "Run complete — 1 action failed")
        #expect(RunSummary.message(for: [entry(.failed), entry(.failed)]) == "Run complete — 2 actions failed")
    }

    @Test func mixedOutcomesAreListedSeparately() {
        let history = [entry(.applied), entry(.applied), entry(.failed), entry(.skipped), entry(.needsConfirmation)]
        #expect(RunSummary.message(for: history) == "Run complete — 2 actions applied, 1 failed, 1 skipped, 1 awaiting confirmation")
    }
}
