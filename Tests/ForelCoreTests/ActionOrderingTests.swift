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

@Suite struct ActionOrderingTests {
    private func actions() -> [Action] {
        ["A", "B", "C"].enumerated().map { index, tag in
            makeAction(.addTag, .object(["tag": .string(tag)]), position: Int64(index))
        }
    }

    private func tags(_ actions: [Action]) -> [String?] {
        actions.map { $0.params["tag"]?.stringValue }
    }

    @Test func movingByOffsetSwapsNeighboursAndRenumbersPositions() {
        var list = actions()
        list.moveAction(at: 0, by: 1)
        #expect(tags(list) == ["B", "A", "C"])
        #expect(list.map(\.position) == [0, 1, 2])
    }

    @Test func movingPastEitherEndDoesNothing() {
        var list = actions()
        list.moveAction(at: 0, by: -1)
        list.moveAction(at: 2, by: 1)
        #expect(tags(list) == ["A", "B", "C"])
    }

    @Test func insertionIndexMovesDownwardsAndUpwards() {
        var list = actions()
        list.moveAction(id: list[0].id, toInsertionIndex: 3)
        #expect(tags(list) == ["B", "C", "A"])

        list.moveAction(id: list[2].id, toInsertionIndex: 0)
        #expect(tags(list) == ["A", "B", "C"])
        #expect(list.map(\.position) == [0, 1, 2])
    }

    @Test func droppingAnActionOnItsOwnSlotKeepsTheOrder() {
        var list = actions()
        list.moveAction(id: list[1].id, toInsertionIndex: 1)
        list.moveAction(id: list[1].id, toInsertionIndex: 2)
        #expect(tags(list) == ["A", "B", "C"])
    }

    @Test func deletingAnActionLeavesContiguousPositions() {
        var list = actions()
        list.remove(at: 1)
        list.normalizeActionPositions()
        #expect(list.map(\.position) == [0, 1])
    }

    @Test func droppingOnARowInsertsAfterItWhenDraggingDownwardsAndBeforeWhenUpwards() {
        var list = actions()
        let first = list[0].id
        let last = list[2].id

        // First action dropped on the row right below it: swap, not a no-op.
        let downwards = list.dropInsertionIndex(onRowAt: 1, dragging: first)
        list.moveAction(id: first, toInsertionIndex: downwards)
        #expect(tags(list) == ["B", "A", "C"])

        // Last action dropped on the first row: lands before it.
        let upwards = list.dropInsertionIndex(onRowAt: 0, dragging: last)
        list.moveAction(id: last, toInsertionIndex: upwards)
        #expect(tags(list) == ["C", "B", "A"])
    }

    @Test func dropInsertionIndexFallsBackToTheRowWhenNothingIsDragged() {
        #expect(actions().dropInsertionIndex(onRowAt: 2, dragging: nil) == 2)
        #expect(actions().dropInsertionIndex(onRowAt: 2, dragging: "unknown") == 2)
    }
}
