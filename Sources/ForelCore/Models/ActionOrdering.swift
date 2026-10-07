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

/// Reordering helpers for a rule's actions. Actions run by `position`, and
/// that is what the database persists, so every move re-numbers positions to
/// match the new array order.
public extension Array where Element == Action {
    /// Rewrites each action's `position` to its index.
    mutating func normalizeActionPositions() {
        for index in indices {
            self[index].position = Int64(index)
        }
    }

    /// Swaps the action at `index` with its neighbour `offset` places away.
    mutating func moveAction(at index: Int, by offset: Int) {
        let destination = index + offset
        guard indices.contains(index), indices.contains(destination) else { return }
        swapAt(index, destination)
        normalizeActionPositions()
    }

    /// Moves the action with `id` so it ends up before the element currently
    /// at `insertionIndex` (`count` means the end of the list).
    mutating func moveAction(id: String, toInsertionIndex insertionIndex: Int) {
        guard let sourceIndex = firstIndex(where: { $0.id == id }) else { return }
        let action = remove(at: sourceIndex)
        let targetIndex = sourceIndex < insertionIndex ? insertionIndex - 1 : insertionIndex
        insert(action, at: Swift.max(0, Swift.min(targetIndex, count)))
        normalizeActionPositions()
    }

    /// Where a drop on the body of the row at `rowIndex` inserts the action
    /// being dragged: before that row when dragging upwards, after it when
    /// dragging downwards — so dropping on the row right below swaps them
    /// instead of being a no-op.
    func dropInsertionIndex(onRowAt rowIndex: Int, dragging id: String?) -> Int {
        guard let id, let sourceIndex = firstIndex(where: { $0.id == id }), sourceIndex < rowIndex else {
            return rowIndex
        }
        return rowIndex + 1
    }
}
